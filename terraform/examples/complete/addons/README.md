# Complete add-ons

Apply this root only after the adjacent foundation is healthy and the workstation or CI runner is connected to OpenVPN. It discovers the private EKS cluster and Karpenter AWS prerequisites from AWS using the known `cluster_name` (equal to the foundation `name`), authenticates to the private API, installs Karpenter 1.14.0, and creates the tested AL2023 EC2NodeClass and general-purpose NodePool.

Discovery contracts (fixed by the foundation `karpenter-infra` module):

| Resource | Name |
|----------|------|
| EKS cluster | `var.cluster_name` |
| Karpenter node IAM role | `${cluster_name}-karpenter-node` |
| Interruption queue | `Karpenter-${cluster_name}` |

Run commands from the repository root after connecting:

```bash
cp terraform/examples/complete/addons/terraform.tfvars.example terraform/examples/complete/addons/terraform.tfvars
# Set cluster_name to the foundation environment name.
make addons-init ENGINE=tofu
tofu -chdir=terraform/examples/complete/addons plan
tofu -chdir=terraform/examples/complete/addons apply
```

This root does not read foundation Terraform state. The commands above use local state and are intended for evaluation. For a durable environment, follow `$deploy-unrealops-infrastructure` and initialize this root with `.agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh`, using a credential-free backend config and state key distinct from the foundation.

Destroy this root before the foundation, while OpenVPN and the private EKS API remain reachable (data sources and providers still need the live cluster and Karpenter AWS objects):

```bash
tofu -chdir=terraform/examples/complete/addons destroy
tofu -chdir=terraform/examples/complete/foundation destroy
```
