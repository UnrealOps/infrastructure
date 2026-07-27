# Cluster Add-ons Module

Installs Karpenter `1.14.0` into an existing private EKS `1.36` cluster. CRDs are managed as a dedicated Helm release, followed by the controller and a local manifest chart containing an AL2023 `EC2NodeClass` and general-purpose `NodePool`. This ordering lets a single apply install or upgrade CRDs before custom resources are evaluated.

## Provider and Usage

The supported add-ons root discovers foundation resources from AWS rather than
reading foundation Terraform state. Configure the Helm provider in that root
after connecting to OpenVPN:

```hcl
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
}

data "aws_sqs_queue" "karpenter_interruption" {
  name = "Karpenter-${var.cluster_name}"
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
  source = "../../modules/cluster-addons"

  cluster_name            = var.cluster_name
  cluster_endpoint        = data.aws_eks_cluster.this.endpoint
  node_iam_role_name      = data.aws_iam_role.karpenter_node.name
  interruption_queue_name = data.aws_sqs_queue.karpenter_interruption.name
  discovery_tag_value     = var.cluster_name
}
```

See `terraform/examples/complete/addons` for the full AWS, Kubernetes, and Helm
provider configuration. Do not introduce `terraform_remote_state`.

The default NodePool permits modern `c`, `m`, and `r` instances across Spot and On-Demand capacity, consolidates empty or underutilized nodes after one minute, limits concurrent disruption to 10%, and expires nodes after 30 days. The pinned `al2023@v20260709` alias matches the tested system-node AMI date.

Use `node_class_tags` only for custom, non-empty AWS tags. Karpenter supplies its cluster, NodePool, NodeClaim, and EC2NodeClass ownership tags automatically, so the module rejects those reserved keys.

Use additional NodePools for GPU, build-farm, or dedicated-server workloads rather than widening the general-purpose defaults. No credentials or Kubernetes tokens are stored by this module.
