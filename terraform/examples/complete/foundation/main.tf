locals {
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
  access_entries                           = local.admin_access_entries
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  deletion_protection                      = var.deletion_protection
  tags                                     = var.tags
}

module "karpenter_infra" {
  source = "../../../modules/karpenter-infra"

  cluster_name = module.eks.cluster_name
  region       = var.aws_region
  tags         = var.tags
}
