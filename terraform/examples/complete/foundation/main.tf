locals {
  lore_runtime_secret_name = coalesce(var.lore_runtime_secret_name, "unrealops/${var.name}/lore/runtime")

  admin_access_entries = {
    for principal_arn in var.admin_principal_arns : "admin-${substr(sha1(principal_arn), 0, 12)}" => {
      principal_arn = principal_arn
      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

module "network" {
  source = "../../../modules/network"

  name               = var.name
  cluster_name       = var.name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  tags               = var.tags
}

module "openvpn" {
  source = "../../../modules/openvpn"

  name                       = var.name
  vpc_id                     = module.network.vpc_id
  vpc_cidr                   = module.network.vpc_cidr
  subnet_ids                 = module.network.vpn_subnet_ids
  runtime_secret_arn         = var.openvpn_runtime_secret_arn
  runtime_secret_kms_key_arn = var.openvpn_runtime_secret_kms_key_arn
  allowed_routes             = [module.network.vpc_cidr]
  ingress_cidrs              = var.openvpn_ingress_cidrs
  instance_type              = var.openvpn_instance_type
  route53_zone_id            = var.openvpn_route53_zone_id
  route53_record_name        = var.openvpn_route53_record_name
  tags                       = var.tags
}

module "eks" {
  source = "../../../modules/eks"

  cluster_name                             = var.name
  vpc_id                                   = module.network.vpc_id
  private_subnet_ids                       = module.network.private_subnet_ids
  vpn_cidr_blocks                          = module.network.vpn_subnet_cidrs
  system_node_instance_types               = var.system_node_instance_types
  system_node_group_size                   = var.system_node_group_size
  access_entries                           = local.admin_access_entries
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  deletion_protection                      = var.deletion_protection
  enable_lore_observability                = var.enable_lore
  tags                                     = var.tags
}

module "karpenter_infra" {
  source = "../../../modules/karpenter-infra"

  cluster_name = module.eks.cluster_name
  region       = var.aws_region
  tags         = var.tags
}

module "cluster_addons_infra" {
  count  = var.enable_lore ? 1 : 0
  source = "../../../modules/cluster-addons-infra"

  cluster_name = module.eks.cluster_name
  tags         = var.tags
}

module "lore_infra" {
  count  = var.enable_lore ? 1 : 0
  source = "../../../modules/lore-infra"

  cluster_name              = module.eks.cluster_name
  vpc_id                    = module.network.vpc_id
  vpc_cidr                  = module.network.vpc_cidr
  node_security_group_id    = module.eks.node_security_group_id
  vpn_source_prefix_list_id = module.network.vpn_source_prefix_list_id
  runtime_secret_name       = local.lore_runtime_secret_name
  deletion_protection       = var.lore_deletion_protection
  force_destroy             = var.lore_force_destroy
  alarm_topic_arn           = var.lore_alarm_topic_arn
  tags                      = var.tags
}
