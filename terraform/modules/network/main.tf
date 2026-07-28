data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required", "opted-in"]
  }
}

locals {
  # Keep calculations valid while Terraform reports an invalid vpc_cidr through
  # the variable validation above.
  calculation_vpc_cidr = try("${cidrhost(var.vpc_cidr, 0)}/16", "10.0.0.0/16")

  available_azs = sort(data.aws_availability_zones.available.names)
  default_azs   = slice(local.available_azs, 0, min(3, length(local.available_azs)))
  azs           = length(var.availability_zones) == 3 ? var.availability_zones : local.default_azs

  # Reserve the first three /19 networks for workers, three adjacent /24s for
  # NAT gateways, and three /28s from the following /24 for VPN appliances.
  default_private_subnet_cidrs = [
    for index in range(3) : cidrsubnet(local.calculation_vpc_cidr, 3, index)
  ]
  default_public_subnet_cidrs = [
    for index in range(3) : cidrsubnet(local.calculation_vpc_cidr, 8, 96 + index)
  ]
  default_vpn_subnet_cidrs = [
    for index in range(3) : cidrsubnet(local.calculation_vpc_cidr, 12, (99 * 16) + index)
  ]

  private_subnet_cidrs = length(var.private_subnet_cidrs) == 3 ? var.private_subnet_cidrs : local.default_private_subnet_cidrs
  public_subnet_cidrs  = length(var.public_subnet_cidrs) == 3 ? var.public_subnet_cidrs : local.default_public_subnet_cidrs
  vpn_subnet_cidrs     = length(var.vpn_subnet_cidrs) == 3 ? var.vpn_subnet_cidrs : local.default_vpn_subnet_cidrs
  all_subnet_cidrs     = concat(local.private_subnet_cidrs, local.public_subnet_cidrs, local.vpn_subnet_cidrs)

  vpc_network_octets = split(".", cidrhost(local.calculation_vpc_cidr, 0))
  subnets_within_vpc = alltrue([
    for cidr in local.all_subnet_cidrs : try(
      split(".", cidrhost(cidr, 0))[0] == local.vpc_network_octets[0] &&
      split(".", cidrhost(cidr, 0))[1] == local.vpc_network_octets[1],
      false,
    )
  ])

  private_child_24_cidrs = flatten([
    for cidr in local.private_subnet_cidrs : [
      for index in range(32) : try(cidrsubnet(cidr, 5, index), "invalid")
    ]
  ])
  private_child_28_cidrs = flatten([
    for cidr in local.private_subnet_cidrs : [
      for index in range(512) : try(cidrsubnet(cidr, 9, index), "invalid")
    ]
  ])
  public_child_28_cidrs = flatten([
    for cidr in local.public_subnet_cidrs : [
      for index in range(16) : try(cidrsubnet(cidr, 4, index), "invalid")
    ]
  ])

  subnets_do_not_overlap = (
    length(distinct(local.private_subnet_cidrs)) == 3 &&
    length(distinct(local.public_subnet_cidrs)) == 3 &&
    length(distinct(local.vpn_subnet_cidrs)) == 3 &&
    length(setintersection(toset(local.private_child_24_cidrs), toset(local.public_subnet_cidrs))) == 0 &&
    length(setintersection(toset(local.private_child_28_cidrs), toset(local.vpn_subnet_cidrs))) == 0 &&
    length(setintersection(toset(local.public_child_28_cidrs), toset(local.vpn_subnet_cidrs))) == 0
  )

  vpn_subnets_by_az = {
    for index, az in local.azs : az => {
      cidr  = local.vpn_subnet_cidrs[index]
      index = index
    }
  }

  common_tags = merge(var.tags, {
    ManagedBy             = "Terraform"
    "unrealops.io/module" = "network"
  })

  private_subnet_tags = merge(var.private_subnet_tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    "karpenter.sh/discovery"                    = var.cluster_name
    "unrealops.io/subnet-role"                  = "eks-private"
  })

  public_subnet_tags = merge(var.public_subnet_tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
    "unrealops.io/subnet-role"                  = "nat-public"
  })
}

resource "terraform_data" "validation" {
  input = {
    availability_zones = local.azs
    subnet_cidrs       = local.all_subnet_cidrs
  }

  lifecycle {
    precondition {
      condition     = length(local.azs) == 3
      error_message = "The selected AWS region must expose at least three availability zones, or availability_zones must specify three valid zones."
    }

    precondition {
      condition     = alltrue([for az in local.azs : contains(local.available_azs, az)])
      error_message = "Every availability_zones entry must be available in the configured AWS region."
    }

    precondition {
      condition     = local.subnets_within_vpc
      error_message = "Every private, public, and VPN subnet must be contained within vpc_cidr."
    }

    precondition {
      condition     = local.subnets_do_not_overlap
      error_message = "Private, public, and VPN subnet CIDRs must be unique and non-overlapping."
    }
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnet_cidrs
  public_subnets  = local.public_subnet_cidrs

  enable_dns_support   = true
  enable_dns_hostnames = true

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  map_public_ip_on_launch = false

  enable_flow_log                                 = true
  flow_log_destination_type                       = "cloud-watch-logs"
  flow_log_traffic_type                           = "ALL"
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_in_days

  private_subnet_tags = local.private_subnet_tags
  public_subnet_tags  = local.public_subnet_tags
  tags                = local.common_tags

  depends_on = [terraform_data.validation]
}

module "s3_endpoint" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.6.1"

  vpc_id = module.vpc.vpc_id

  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags = {
        Name = "${var.name}-s3"
      }
    }
  }

  tags = local.common_tags
}

resource "aws_subnet" "vpn" {
  for_each = local.vpn_subnets_by_az

  vpc_id                  = module.vpc.vpc_id
  availability_zone       = each.key
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, var.vpn_subnet_tags, {
    Name                       = "${var.name}-vpn-${each.key}"
    "unrealops.io/subnet-role" = "vpn-public"
  })
}

resource "aws_route_table" "vpn" {
  for_each = local.vpn_subnets_by_az

  vpc_id = module.vpc.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.name}-vpn-${each.key}"
  })
}

resource "aws_route" "vpn_internet" {
  for_each = local.vpn_subnets_by_az

  route_table_id         = aws_route_table.vpn[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc.igw_id
}

resource "aws_route_table_association" "vpn" {
  for_each = local.vpn_subnets_by_az

  subnet_id      = aws_subnet.vpn[each.key].id
  route_table_id = aws_route_table.vpn[each.key].id
}

resource "aws_ec2_managed_prefix_list" "vpn_source" {
  name           = "${var.name}-vpn-source"
  address_family = "IPv4"
  max_entries    = length(local.vpn_subnet_cidrs)

  dynamic "entry" {
    for_each = local.vpn_subnets_by_az

    content {
      cidr        = entry.value.cidr
      description = "VPN appliance subnet in ${entry.key}"
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-vpn-source"
  })
}
