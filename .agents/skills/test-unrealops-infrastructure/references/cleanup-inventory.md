# Acceptance Cleanup Inventory

For run ID `<id>`, derive these owners:

```text
unrealops-e2e-<id>
unrealops-bootstrap-<id>
unrealops-network-<id>
unrealops-vpn-<id>
```

Search only the explicitly authorized account and region. Use exact tag selectors:

```text
Environment=unrealops-e2e-<id>
Test=unrealops-bootstrap-<id>
Test=unrealops-network-<id>
Test=unrealops-vpn-<id>
ClusterName=unrealops-e2e-<id>
karpenter.sh/discovery=unrealops-e2e-<id>
eks:cluster-name=unrealops-e2e-<id>
eks:eks-cluster-name=unrealops-e2e-<id>
aws:eks:cluster-name=unrealops-e2e-<id>
kubernetes.io/cluster/unrealops-e2e-<id>=owned|shared
```

Resource Groups Tagging API is useful but insufficient by itself; AWS-generated and recently deleted resources may be untagged or delayed.

## Regional resources

- VPC, subnets, route tables and associations, internet gateway, three NAT gateways/EIPs, S3 and DynamoDB gateway endpoints, flow log/log group, managed VPN prefix list, security groups, and ENIs.
- OpenVPN ASG/lifecycle hook, launch template, instance, encrypted volume, EIP, security group, and `/unrealops/<name>/openvpn` log group. Audit untagged orphan ENIs through the exact `Module=openvpn` security group inside the run-owned VPC; do not rely on an ENI `Name` tag.
- EKS cluster, five baseline add-ons plus the optional CloudWatch Observability add-on, system node group/service ASG, instances/volumes/ENIs, launch template, access entries, Pod Identity associations, security groups, `/aws/eks/<cluster>/cluster`, and the Terraform-managed `/aws/containerinsights/<cluster>/*` log groups.
- Karpenter SQS interruption queue, five EventBridge rules/targets, acceptance Deployment/NodeClaim/node, generated launch template and instance profile, EC2 instance, volume, and ENI.
- With Lore enabled: the ECR repository/images, S3 bucket/object versions, four DynamoDB tables, exact temporary `<cluster>-lore-pitr-restore` table, private hosted zone/record, NLB/listener/target groups/security group, Lore and controller Pod Identity associations/roles/policies, edge NodeClaims/nodes/volumes/ENIs, alarms/dashboard, and `/aws/lore/<cluster>/metrics`.
- Both exact OpenVPN Secrets Manager runtime bundles plus the optional deterministic Lore runtime bundle, which Terraform intentionally does not own.

Treat terminated EC2 instances, `deleted` NAT gateways, and secrets with a deletion date as terminal cleanup states.

## Global IAM resources

Constrain checks to exact run-owned names/tags:

- OpenVPN roles and instance profiles for complete and fixture stacks.
- Standalone `unrealops-bootstrap-<id>` EKS administrator test role and its inline discovery policy.
- EKS cluster, system node, EBS CSI, CloudWatch Observability, Karpenter controller/node, AWS Load Balancer Controller, and Lore edge/write/OTel roles.
- Cluster-encryption customer-managed policy and run-tagged VPC flow-log role/policy.
- Karpenter-generated instance profile. Its name is `<cluster>_<hash>` rather than the module's hyphenated IAM names; require the cluster's ownership or discovery tag before treating it as run-owned.
- The EKS OIDC provider captured from state or logs.

Do not delete shared AWS service-linked roles for EKS, Auto Scaling, or EC2 Spot.

## Pass criteria

All five Terraform states have no managed resources or locks. Direct and tag-based checks find no active run-owned regional resource, IAM resource, OIDC provider, runtime secret, CloudWatch group, KMS alias, or Karpenter artifact. Every run-tagged ARN is a failure unless it is the separately validated expected KMS key or one of the exact runtime secrets checked below.

The expected scheduled remnant is the EKS customer-managed KMS key and, when Lore acceptance is enabled, the separate Lore storage key. Require matching run-manifest cleanup markers, `KeyState=PendingDeletion`, `Enabled=false`, deletion dates, and no aliases targeting either key. The EKS key can use an exact run ownership tag only for manual recovery without a manifest. A manifest-linked key that returns `NotFoundException` is fully deleted and is also terminal; a direct key ID returning not found cannot prove ownership. An unrelated key is never acceptable evidence. An enabled key, surviving alias, missing run-linked evidence, or any other active resource fails the audit. Record both key IDs and deletion dates in the test report.
