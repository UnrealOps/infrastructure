# EKS Module

Creates the opinionated EKS control plane and stable system capacity for a
studio. The module pins Kubernetes `1.36`, uses a private-only API endpoint,
enables all control-plane logs, KMS secret encryption, and VPC CNI network
policy enforcement, and creates an AL2023 on-demand managed node group. The
default is two `m6i.large` nodes across Availability Zones so the
repository's two-replica controllers can remain separated. Karpenter-managed
workload capacity is installed separately.

## Usage

```hcl
module "eks" {
  source = "../../modules/eks"

  cluster_name       = "studio-dev"
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  # OpenVPN SNAT makes traffic originate from its appliance subnets.
  vpn_cidr_blocks = module.network.vpn_subnet_cidrs

  system_node_group_size = {
    min     = 2
    desired = 2
    max     = 3
  }

  access_entries = {
    platform_admins = {
      principal_arn = "arn:aws:iam::123456789012:role/platform-admin"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  tags = {
    Environment = "dev"
    ManagedBy   = "OpenTofu"
  }
}
```

Run Terraform/OpenTofu from a host connected to OpenVPN before configuring Kubernetes or Helm providers. The public EKS endpoint cannot be enabled through this module.

The two-node default provides system add-on availability during failures and
maintenance. Increase `system_node_group_size` for larger control-plane add-on
loads, or select other validated on-demand instance types through
`system_node_instance_types`.

## Compatibility Policy

Each repository release selects a non-overridable, repository-tested version set. This release uses EKS `1.36`, AL2023 release `1.36.2-20260709`, and explicit managed add-on versions. These pins are private locals in `compatibility.tf`; change them only in a dependency PR that runs the full Terratest suite with both Terraform and OpenTofu.

The optional Lore path installs
`amazon-cloudwatch-observability` `v6.2.0-eksbuild.1` through EKS Pod Identity,
enables OTel Container Insights, and disables Application Signals
auto-monitoring. The four Container Insights log groups are managed with the
same retention period as the EKS control-plane logs, so they are included in
Terraform teardown. CloudWatch and X-Ray policies attach only to the add-on
role.

The initial `v0.1.0` interface does not accept `cluster_version`,
`system_node_ami_release_version`, or `cluster_addon_versions`. Custom managed
add-on version overrides are not supported; upgrade the repository release to
adopt a newly tested version set.

The Terraform caller receives temporary cluster-admin access by default for turn-key bootstrapping. Add a durable administrative access entry, then set `enable_cluster_creator_admin_permissions = false` for long-lived environments. Enable `deletion_protection` outside ephemeral test environments.
