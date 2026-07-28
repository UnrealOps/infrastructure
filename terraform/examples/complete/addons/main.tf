locals {
  node_iam_role_name      = "${var.cluster_name}-karpenter-node"
  interruption_queue_name = "Karpenter-${var.cluster_name}"
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

  cluster_name            = var.cluster_name
  cluster_endpoint        = data.aws_eks_cluster.this.endpoint
  node_iam_role_name      = data.aws_iam_role.karpenter_node.name
  interruption_queue_name = data.aws_sqs_queue.karpenter_interruption.name
  discovery_tag_value     = var.cluster_name
  node_class_tags         = var.tags
}
