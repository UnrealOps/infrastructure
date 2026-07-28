# Karpenter Infrastructure Module

Creates the AWS-side resources required by Karpenter: least-privilege controller and node IAM roles, EKS Pod Identity, an `EC2_LINUX` access entry, and an encrypted interruption queue with EventBridge rules. It wraps the Karpenter submodule from `terraform-aws-modules/eks/aws` at exactly `21.24.0`.

## Usage

```hcl
module "karpenter_infra" {
  source = "../../modules/karpenter-infra"

  cluster_name = module.eks.cluster_name
  region       = "us-west-2"

  tags = {
    Environment = "dev"
    ManagedBy   = "OpenTofu"
  }
}
```

Pass `node_iam_role_name` and `interruption_queue_name` to the `cluster-addons` module. Names are fixed (no prefixes) so a later add-ons root can discover them from AWS without reading foundation state:

| Resource | Name |
| --- | --- |
| Controller IAM role | `${cluster_name}-karpenter-controller` |
| Node IAM role | `${cluster_name}-karpenter-node` |
| Interruption queue | `Karpenter-${cluster_name}` |

The node role includes the standard EKS worker, ECR pull-only, VPC CNI, and SSM Session Manager policies. Use `additional_node_policy_arns` for workload-specific permissions only when Pod Identity cannot be used.

This module must run after the EKS cluster because it creates an access entry and Pod Identity association. It does not connect to the Kubernetes API and can therefore be included in the foundation stage.
