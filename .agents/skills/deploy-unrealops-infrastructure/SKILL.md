---
name: deploy-unrealops-infrastructure
description: Deploy, verify, or destroy the supported UnrealOps AWS network, OpenVPN, private EKS, and Karpenter stack. Use when asked to plan or apply the complete foundation, connect through its VPN, install cluster add-ons, inspect deployment health, or safely tear down a studio environment.
---

# Deploy UnrealOps Infrastructure

Operate only the supported roots:

- `terraform/examples/complete/foundation` creates the VPC, OpenVPN, private EKS cluster, system nodes, and Karpenter AWS prerequisites.
- `terraform/examples/complete/addons` installs Karpenter through the private Kubernetes API.

Read [references/deployment-runbook.md](references/deployment-runbook.md) before a plan, apply, or destroy.

## Enforce the safety gate

1. Obtain an explicit AWS account ID and region. Never infer either from a default profile.
2. Export both `AWS_REGION` and `AWS_DEFAULT_REGION`, then compare `aws sts get-caller-identity --region "$AWS_REGION"` with the expected account.
3. Get explicit authorization before creating billable resources. State the main cost drivers: EKS, NAT gateways, EC2, EIPs, CloudWatch, and KMS.
4. Use one engine throughout; prefer OpenTofu unless the user requests Terraform.
5. Scope every AWS command to the authorized region. Never inspect or clean another region as a convenience.
6. Preserve existing state, PKI, secrets, and unrelated resources. Reject a local-state deployment if either example root already contains an unexpected environment.
7. Re-run the exact-account check immediately before `vpn-pki-init` and every saved-plan apply. A check performed before planning is not sufficient authorization for a later write.

For a plan-only request, stop before `vpn-pki-init` because it writes a billable Secrets Manager secret. Collect the required name, CIDR, ingress, administrators, state, and deletion-protection choices; use an existing secret ARN or a clearly labeled syntactically valid placeholder. Plan only the foundation. The add-ons root cannot produce a meaningful plan until the live cluster exists in AWS (data sources), the private API is reachable over VPN, and `cluster_name` matches the foundation environment name.

## Follow the two-phase workflow

1. Run `make check ENGINE=<engine>` and `make security`, then review input CIDRs, administrator principals, quotas, and backend configuration. Version pins are private source constants selected by the repository release, not deployment inputs. Durable environments require separate encrypted, locked remote state for both roots; initialize each with `.agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh` and a credential-free config file stored outside the repository.
2. Create the offline OpenVPN CA/runtime secret with `make vpn-pki-init`. Keep the CA private; only the runtime bundle belongs in Secrets Manager.
3. Copy and edit the foundation example variables. Initialize, save and inspect a plan, then apply the foundation.
4. Generate a named client profile, connect OpenVPN, and prove the private EKS endpoint is reachable. Validate a durable administrator session, then disable temporary cluster-creator administrator access with another reviewed foundation plan.
5. Copy and edit the add-ons variables (`aws_region`, `cluster_name` equal to the foundation `name`, and tags). Initialize, save and inspect a plan, then apply it while the VPN remains connected. Do not configure foundation remote state on the add-ons root.
6. Verify the pinned EKS version and add-ons, private-only API, system nodes, Karpenter controller, `EC2NodeClass`, and `NodePool`. For functional verification, create a disposable Karpenter workload and wait for its node to consolidate after deletion.
7. Retain the backend coordinates, both state lineages, populated inputs, runtime secret ARN, its external encryption key when configured, the EKS KMS key ARN, optional Route 53 record coordinates, and PKI recovery information in the studio's approved encrypted operations store so another operator can plan or destroy from a clean checkout.

## Tear down in dependency order

Delete workloads and Karpenter NodeClaims first. Match both initialized state lineages to the retained handoff, destroy add-ons while the VPN and cluster API still work, disconnect, then destroy the foundation. Run `.agents/skills/deploy-unrealops-infrastructure/scripts/audit-cleanup.sh` with both lineages, the exact VPC ID, and an explicit Route 53 configured/not-configured decision to require empty managed state and no exact-name/tag resources before deleting the external runtime secret; then run it again after scheduling secret deletion. Treat only the recorded EKS KMS key in `PendingDeletion` as a scheduled remnant, and only when every alias is gone and the key is disabled; report its ID and deletion date.
