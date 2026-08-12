# Bootstrap EKS administrator access

This root creates the durable IAM role used by the complete foundation's `admin_principal_arns` input. It has its own lifecycle because an identity used to recover or replace a cluster must not depend on that cluster's state.

The role has only enough AWS permissions to list EKS clusters and describe the cluster names configured here. The foundation separately associates `AmazonEKSClusterAdminPolicy` through an EKS access entry; the bootstrap role is not an AWS account administrator or infrastructure deployment role.

## Apply

Authenticate with an existing bootstrap identity that may create IAM roles, then review the account and identity before applying:

```bash
aws sts get-caller-identity --region us-west-2
cp terraform/examples/account-bootstrap/terraform.tfvars.example \
  terraform/examples/account-bootstrap/terraform.tfvars
# Edit aws_region, cluster_names, and trusted_principal_arns before continuing.
make account-bootstrap-init ENGINE=tofu
tofu -chdir=terraform/examples/account-bootstrap plan -out=tfplan
tofu -chdir=terraform/examples/account-bootstrap show tfplan
tofu -chdir=terraform/examples/account-bootstrap apply tfplan
tofu -chdir=terraform/examples/account-bootstrap output admin_principal_arns
```

When `trusted_principal_arns` is empty, the example resolves temporary credentials to their permanent IAM issuer. This supports IAM Identity Center and assumed-role sessions without putting an invalid STS session ARN in the trust policy or EKS access entry. Confirm the resolved `trusted_principal_arns` value in every saved plan.

Copy the `admin_principal_arns` output into `terraform/examples/complete/foundation/terraform.tfvars`. Apply the foundation with `enable_cluster_creator_admin_permissions = true` until you have assumed the new role and verified Kubernetes access; then set it to `false` and apply again.

## Assume and use the role

Your source identity must be allowed to call `sts:AssumeRole`. Configure a named AWS profile using the `eks_admin_role_arn` output:

```ini
[profile unrealops-eks-admin]
role_arn = arn:aws:iam::123456789012:role/unrealops/StudioEKSAdministrators
source_profile = your-bootstrap-profile
region = us-west-2
```

After the foundation is applied:

```bash
aws --profile unrealops-eks-admin eks update-kubeconfig --name studio-dev --region us-west-2
kubectl auth can-i '*' '*' --all-namespaces
```

Store this root's state in a durable, access-controlled backend separate from foundation and add-ons. Remove a cluster's EKS access entry before removing the corresponding cluster name or destroying this role.
