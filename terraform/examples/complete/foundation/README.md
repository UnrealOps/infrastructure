# Complete foundation

This root creates the network, single-instance OpenVPN gateway, private EKS 1.36 cluster, stable system node group, and Karpenter AWS prerequisites. It intentionally does not install Helm charts because its EKS endpoint has no public access.

Run commands from the repository root:

```bash
make vpn-pki-init ENV=studio-dev AWS_REGION=us-west-2
cp terraform/examples/complete/foundation/terraform.tfvars.example terraform/examples/complete/foundation/terraform.tfvars
# Set openvpn_runtime_secret_arn and durable admin_principal_arns in terraform.tfvars.
make foundation-init ENGINE=tofu
tofu -chdir=terraform/examples/complete/foundation plan
tofu -chdir=terraform/examples/complete/foundation apply
make vpn-client ENV=studio-dev USER=alice ENDPOINT="$(tofu -chdir=terraform/examples/complete/foundation output -raw openvpn_endpoint)"
```

Connect with the generated profile before applying `../addons` with `cluster_name` set to this root's `name`. The add-ons root discovers the cluster from AWS; it does not read this root's Terraform state. To tear down the environment, destroy add-ons while the VPN and private API are reachable, then destroy this foundation. Never destroy the foundation first.

The commands above use local state and are intended for evaluation. Durable environments require distinct encrypted, locked remote state for both roots. Follow `$deploy-unrealops-infrastructure`; its `.agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh` helper initializes this root from a credential-free backend config stored outside the repository. Set `deletion_protection = true`, and keep at least one durable administrator access entry before disabling creator-admin permissions.
