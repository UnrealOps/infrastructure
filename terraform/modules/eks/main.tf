data "aws_partition" "current" {}

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    sid     = "EKSPodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "cloudwatch_observability_assume_role" {
  statement {
    sid     = "EKSPodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  description        = "EKS Pod Identity role for the Amazon EBS CSI driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role" "cloudwatch_observability" {
  count = var.enable_lore_observability ? 1 : 0

  name               = "${var.cluster_name}-cloudwatch-observability"
  description        = "EKS Pod Identity role for the CloudWatch Observability add-on"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_observability_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  count = var.enable_lore_observability ? 1 : 0

  role       = aws_iam_role.cloudwatch_observability[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_xray" {
  count = var.enable_lore_observability ? 1 : 0

  role       = aws_iam_role.cloudwatch_observability[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

locals {
  control_plane_subnet_ids = length(var.control_plane_subnet_ids) > 0 ? var.control_plane_subnet_ids : var.private_subnet_ids
  container_insights_log_group_suffixes = toset([
    "application",
    "dataplane",
    "host",
    "performance",
  ])

  cluster_addons = {
    vpc-cni = {
      addon_version               = local.cluster_addon_versions.vpc_cni
      before_compute              = true
      configuration_values        = jsonencode({ enableNetworkPolicy = "true" })
      most_recent                 = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    eks-pod-identity-agent = {
      addon_version               = local.cluster_addon_versions.pod_identity_agent
      before_compute              = true
      most_recent                 = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      addon_version               = local.cluster_addon_versions.kube_proxy
      most_recent                 = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns = {
      addon_version               = local.cluster_addon_versions.coredns
      most_recent                 = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      addon_version               = local.cluster_addon_versions.ebs_csi_driver
      most_recent                 = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  lore_observability_addon = var.enable_lore_observability ? {
    amazon-cloudwatch-observability = {
      addon_version = local.cluster_addon_versions.cloudwatch_observability
      configuration_values = jsonencode({
        containerInsights = {
          enabled = false
        }
        otelContainerInsights = {
          enabled = true
        }
        manager = {
          applicationSignals = {
            autoMonitor = {
              monitorAllServices = false
            }
          }
        }
      })
      most_recent                 = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      pod_identity_association = [{
        role_arn        = aws_iam_role.cloudwatch_observability[0].arn
        service_account = "cloudwatch-agent"
      }]
    }
  } : {}
}

resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = var.enable_lore_observability ? local.container_insights_log_group_suffixes : toset([])

  name              = "/aws/containerinsights/${var.cluster_name}/${each.value}"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = var.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name               = var.cluster_name
  kubernetes_version = local.cluster_version

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  access_entries                           = var.access_entries

  endpoint_private_access = true
  endpoint_public_access  = false

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = local.control_plane_subnet_ids

  compute_config = {
    enabled = false
  }

  deletion_protection = var.deletion_protection
  upgrade_policy = {
    support_type = "STANDARD"
  }

  enabled_log_types                      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_retention_days

  encryption_config = {
    resources = ["secrets"]
  }
  create_kms_key          = true
  enable_kms_key_rotation = true
  kms_key_administrators  = var.kms_key_administrators

  security_group_additional_rules = {
    vpn_https = {
      description = "Kubernetes API access from OpenVPN appliance subnets"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = var.vpn_cidr_blocks
    }
  }

  addons = merge(local.cluster_addons, local.lore_observability_addon)

  eks_managed_node_groups = {
    system = {
      name                           = "${var.cluster_name}-system"
      kubernetes_version             = local.cluster_version
      ami_type                       = "AL2023_x86_64_STANDARD"
      ami_release_version            = local.system_node_ami_release_version
      use_latest_ami_release_version = false
      iam_role_use_name_prefix       = false
      capacity_type                  = "ON_DEMAND"
      instance_types                 = var.system_node_instance_types
      min_size                       = var.system_node_group_size.min
      desired_size                   = var.system_node_group_size.desired
      max_size                       = var.system_node_group_size.max

      labels = {
        "karpenter.sh/controller" = "true"
        "unrealops.io/node-role"  = "system"
      }

      update_config = {
        max_unavailable = 1
      }

      node_repair_config = {
        enabled = true
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_put_response_hop_limit = 1
        http_tokens                 = "required"
      }

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            delete_on_termination = true
            encrypted             = true
            kms_key_id            = var.system_node_volume_kms_key_id
            volume_size           = var.system_node_volume_size
            volume_type           = "gp3"
          }
        }
      }

      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      tags = merge(var.tags, {
        "karpenter.sh/discovery" = var.cluster_name
      })
    }
  }

  node_security_group_tags = merge(var.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })

  tags = var.tags

  depends_on = [aws_cloudwatch_log_group.container_insights]
}
