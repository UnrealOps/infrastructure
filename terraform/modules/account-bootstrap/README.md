# Account bootstrap module

Creates a durable IAM role for human EKS administration. The role can list EKS clusters and describe only the named clusters; Kubernetes permissions are granted separately when the foundation adds the role to `admin_principal_arns`.

The module intentionally does not create AWS infrastructure-deployment permissions, IAM users, access keys, or an EKS cluster. Trust must name exact, permanent IAM role or user ARNs. Prefer an AWS IAM Identity Center permission-set role for people and use a user ARN only for small tutorial accounts that have not adopted federation.

Keep this module's state independent from the EKS foundation. That allows the administrator identity to exist before the cluster and survive cluster replacement.

```hcl
module "account_bootstrap" {
  source = "../../modules/account-bootstrap"

  cluster_names = ["studio-dev"]
  trusted_principal_arns = [
    "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/us-west-2/AWSReservedSSO_Administrators_0123456789abcdef",
  ]
}
```

Use `module.account_bootstrap.admin_principal_arns` as the value for the foundation's `admin_principal_arns` input.
