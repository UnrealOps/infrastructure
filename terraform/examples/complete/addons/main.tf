locals {
  node_iam_role_name      = "${var.cluster_name}-karpenter-node"
  interruption_queue_name = "Karpenter-${var.cluster_name}"
}

resource "terraform_data" "lore_configuration" {
  input = var.enable_lore

  lifecycle {
    precondition {
      condition     = !var.enable_lore || var.lore_image != null
      error_message = "lore_image is required when enable_lore is true."
    }
  }
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_iam_role" "karpenter_node" {
  name = local.node_iam_role_name
}

data "aws_sqs_queue" "karpenter_interruption" {
  name = local.interruption_queue_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", var.cluster_name,
      "--region", var.aws_region,
    ]
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", var.cluster_name,
        "--region", var.aws_region,
      ]
    }
  }
}

module "cluster_addons" {
  source = "../../../modules/cluster-addons"

  cluster_name             = var.cluster_name
  cluster_endpoint         = data.aws_eks_cluster.this.endpoint
  aws_region               = var.aws_region
  vpc_id                   = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  enable_lore_dependencies = var.enable_lore
  node_iam_role_name       = data.aws_iam_role.karpenter_node.name
  interruption_queue_name  = data.aws_sqs_queue.karpenter_interruption.name
  discovery_tag_value      = var.cluster_name
  node_class_tags          = var.tags
}

module "lore_workload" {
  count  = var.enable_lore ? 1 : 0
  source = "../../../modules/lore-workload"

  cluster_name              = var.cluster_name
  image                     = var.lore_image
  runtime_secret_name       = var.lore_runtime_secret_name
  edge_replicas             = var.lore_edge_replicas
  write_replicas            = var.lore_write_replicas
  edge_instance_types       = var.lore_edge_instance_types
  edge_cache_max_size_bytes = var.lore_edge_cache_max_size_bytes
  alarm_topic_arn           = var.lore_alarm_topic_arn
  tags                      = var.tags

  depends_on = [
    module.cluster_addons,
    terraform_data.lore_configuration,
  ]
}
