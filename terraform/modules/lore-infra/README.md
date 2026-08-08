# Lore AWS infrastructure

This provider-free module creates the durable AWS side of Lore: private ECR,
S3/KMS fragment storage, the four exact Lore v0.8.5 DynamoDB schemas, Pod
Identity roles, private DNS, a VPN-restricted NLB security group, and baseline
alarms.

The runtime certificate secret is discovered by deterministic name. Its value
is never read by Terraform and must be created first with
`scripts/lore-pki.sh init`.
