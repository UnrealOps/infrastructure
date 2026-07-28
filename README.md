# UnrealOps Infrastructure

Reusable Terraform and OpenTofu modules for isolated game-studio infrastructure on AWS. The initial supported vertical slice provisions a private Amazon EKS 1.36 cluster, Karpenter capacity, and a self-hosted OpenVPN Community gateway for employee access without AWS Client VPN hourly connection charges.

## Supported modules

| Module | Purpose |
| --- | --- |
| `network` | Three-AZ VPC, private EKS subnets, per-AZ NAT, and dedicated VPN appliance subnets |
| `openvpn` | Single self-healing OpenVPN instance with a stable Elastic IP |
| `eks` | Private EKS 1.36 control plane and an AL2023 system node group |
| `karpenter-infra` | IAM and interruption-handling resources required by Karpenter |
| `cluster-addons` | Pinned Karpenter chart, EC2NodeClass, and NodePool |

The complete deployment is intentionally split because the Kubernetes and Helm providers cannot reach a private EKS API until the operator connects through OpenVPN.

## Repository layout

- `terraform/modules/` contains the five supported reusable modules above.
- `terraform/examples/complete/foundation` creates AWS infrastructure; `addons` configures Karpenter through the private Kubernetes API.
- `terraform/tests/` contains contract checks, Terratest fixtures, and the complete acceptance suite.
- `scripts/` contains validation and OpenVPN PKI helpers.
- `.agents/skills/` contains agent runbooks and guarded automation for deployment and acceptance testing.

Agents should use `$deploy-unrealops-infrastructure` for the two-phase operator workflow and `$test-unrealops-infrastructure` for static checks, live Terratest, failure recovery, and cleanup auditing.

## Quick start

Prerequisites are credentials for an isolated AWS account, OpenTofu or Terraform, AWS CLI v2, kubectl, OpenVPN, Go, GNU Make, TFLint, Trivy, `curl`, `jq`, OpenSSL, `tar`, and `sha256sum` or `shasum`.

Before any AWS write, confirm the intended account and region with `aws sts get-caller-identity --region us-west-2`. Applying this example creates billable EKS, NAT gateway, public IPv4, EC2, CloudWatch, KMS, and Secrets Manager resources. Use the deployment skill for guarded, durable environments.

```bash
cp terraform/examples/complete/foundation/terraform.tfvars.example terraform/examples/complete/foundation/terraform.tfvars
cp terraform/examples/complete/addons/terraform.tfvars.example terraform/examples/complete/addons/terraform.tfvars
make vpn-pki-init ENV=studio-dev AWS_REGION=us-west-2
# Add the runtime secret ARN and administrator principals to foundation/terraform.tfvars.
make foundation-init ENGINE=tofu
tofu -chdir=terraform/examples/complete/foundation plan
tofu -chdir=terraform/examples/complete/foundation apply
make vpn-client ENV=studio-dev USER="$USER" ENDPOINT="$(tofu -chdir=terraform/examples/complete/foundation output -raw openvpn_endpoint)"
# Connect the generated profile, set addons cluster_name to the foundation name, then:
make addons-init ENGINE=tofu
tofu -chdir=terraform/examples/complete/addons plan
tofu -chdir=terraform/examples/complete/addons apply
```

The add-ons root does not read foundation Terraform state. It discovers the cluster endpoint, CA, Karpenter node role, and interruption queue from AWS using the known `cluster_name` (equal to the foundation `name`).

Review every plan before applying. The OpenVPN server is deliberately one instance: Auto Scaling replaces failures and reclaims its EIP, but active tunnels reconnect during recovery.

Destroy add-ons while still connected to OpenVPN, then destroy the foundation:

```bash
tofu -chdir=terraform/examples/complete/addons destroy
tofu -chdir=terraform/examples/complete/foundation destroy
```

The OpenVPN runtime secret and offline CA are not owned by these roots. Remove the secret separately when retiring an environment, and retain or destroy the offline CA according to studio policy.

## Version and test policy

Tested EKS, managed add-on, system-node AMI, Karpenter, and OpenVPN versions are private source constants. Callers adopt them by upgrading the repository release rather than following a moving `latest` value or overriding individual pins.

The repository is versioned as one tested module suite with Semantic Versioning tags (`vMAJOR.MINOR.PATCH`). Consumers must pin an immutable tag instead of a branch, for example `git::https://github.com/UnrealOps/infrastructure.git//terraform/modules/network?ref=v0.1.0`.

Dependency lockfiles are generated locally and ignored. Modules and examples declare bounded provider constraints in source so both Terraform and OpenTofu can resolve compatible providers.

Run `make check && make security` before opening a pull request. AWS acceptance tests are opt-in and billable; use the guarded wrapper so PKI creation, serialization, failure recovery, secret removal, and the regional cleanup audit stay coupled:

```bash
.agents/skills/test-unrealops-infrastructure/scripts/run-acceptance.sh \
  --engine tofu --account-id 123456789012 --region us-west-2 \
  --run-id tofu-12345 --confirm-billable
```

The current scope ends at network, VPN, EKS, and Karpenter deployment. Game-service workloads and supporting products will be introduced as separately tested future modules.
