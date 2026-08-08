# Complete foundation

This root creates the network, single-instance OpenVPN gateway, private EKS
1.36 cluster, two-node `m6i.large` system group, and Karpenter AWS
prerequisites. Lore
is an opt-in extension that adds durable S3/DynamoDB storage, private ECR,
private DNS, Pod Identity roles, controller IAM, and CloudWatch
observability. It intentionally does not install Helm charts because its EKS
endpoint has no public access.

`system_node_group_size` exposes the managed node group's `min`, `desired`, and
`max` values. The default is `2/2/3` on `m6i.large`, allowing default
two-replica controllers to run on separate system nodes. Increase those values
or select other validated on-demand instance types as the add-on load grows.

OpenVPN remains a singleton because its Auto Scaling Group owns one stable EIP
and endpoint; it is not a horizontally scalable tier. Lore desired capacity is
configured separately in the add-ons root and fulfilled by Karpenter.

Run commands from the repository root:

```bash
make vpn-pki-init ENV=studio-dev AWS_REGION=us-west-2
make lore-pki-init CLUSTER_NAME=studio-dev AWS_REGION=us-west-2
cp terraform/examples/complete/foundation/terraform.tfvars.example terraform/examples/complete/foundation/terraform.tfvars
# Set openvpn_runtime_secret_arn and durable admin_principal_arns in terraform.tfvars.
make foundation-init ENGINE=tofu
tofu -chdir=terraform/examples/complete/foundation plan
tofu -chdir=terraform/examples/complete/foundation apply
make vpn-client ENV=studio-dev USER=alice ENDPOINT="$(tofu -chdir=terraform/examples/complete/foundation output -raw openvpn_endpoint)"
```

Run the Lore PKI command only when `enable_lore = true`. It creates the
deterministic `unrealops/studio-dev/lore/runtime` secret without exposing
certificate material to Terraform state. The encrypted Lore CA remains under
`~/.config/unrealops/lore-pki/studio-dev` and is separate from the OpenVPN CA.

Connect with the generated profile before applying `../addons` with `cluster_name` set to this root's `name`. The add-ons root discovers the cluster from AWS; it does not read this root's Terraform state. To tear down the environment, destroy add-ons while the VPN and private API are reachable, then destroy this foundation. Never destroy the foundation first.

The commands above use local state and are intended for evaluation. Durable
environments require distinct encrypted, locked remote state for both roots.
Follow `$deploy-unrealops-infrastructure`; its
`.agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh` helper
initializes this root from a credential-free backend config stored outside the
repository. Set `deletion_protection = true`, retain
`lore_deletion_protection = true`, leave `lore_force_destroy = false`, and keep
at least one durable administrator access entry before disabling creator-admin
permissions.
