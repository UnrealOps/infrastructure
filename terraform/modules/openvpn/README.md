# OpenVPN Community Module

This module runs OpenVPN Community Edition 2.7.5 on one Ubuntu 24.04 amd64
instance. An Auto Scaling group replaces failed instances and reuses one Elastic
IP. It is intentionally a low-cost, single-appliance design: replacement can
interrupt active sessions for several minutes.

## Architecture

- ASG `min`, `max`, and `desired` capacity are fixed at one across two or more
  supplied public VPN subnets.
- A launch lifecycle hook holds each replacement out of service while it loads
  its runtime secret, disables source/destination checking, starts OpenVPN, and
  passes a local health check. Only then does it take the stable EIP.
- A one-minute watchdog marks the instance unhealthy after repeated failures.
- nftables permits VPN forwarding and SNAT only to `allowed_routes`. The module
  rejects `0.0.0.0/0`, so it cannot become a full-tunnel internet gateway.
- The pushed DNS resolver must be inside an `allowed_routes` CIDR, so a custom
  resolver cannot bypass the split-tunnel forwarding boundary.
- The client address pool is validated not to overlap the VPC or any permitted
  route, preventing ambiguous routing on clients and the appliance.
- Administration uses SSM Session Manager. There is no SSH ingress and the SSH
  service is disabled. IMDSv2, encrypted gp3 storage, CloudWatch logs, CRLs,
  `tls-crypt`, TLS 1.2+, and AEAD data ciphers are enforced.

Because client traffic is SNATed, destination security groups see the
appliance's private address. Allow HTTPS to a private EKS endpoint from the
dedicated VPN subnet CIDRs, not from this module's security-group ID.

## Runtime Secret and PKI

Create the secret before applying Terraform:

```bash
aws sts get-caller-identity --region us-west-2
scripts/openvpn-pki.sh init \
  --environment studio-dev \
  --secret-id unrealops/studio-dev/openvpn/runtime \
  --region us-west-2
```

Confirm the returned account before continuing. The helper creates or updates a
billable Secrets Manager secret that remains outside Terraform ownership.
The helper pins and verifies Easy-RSA 3.2.6. It retains the encrypted CA under
`~/.config/unrealops/pki/studio-dev`; back this directory up to secure offline
storage. The Secrets Manager JSON uses schema version `1` and base64 values for
`ca_crt`, `server_crt`, `server_key`, `crl_pem`, and `tls_crypt_key`. The CA key
and client keys are never uploaded.

Issue and revoke one certificate per employee:

```bash
scripts/openvpn-pki.sh client --environment studio-dev \
  --name alice --endpoint vpn.example.com
scripts/openvpn-pki.sh revoke --environment studio-dev --name alice
```

Profiles are written with mode `0600`. The server checks Secrets Manager every
five minutes and reloads when the published CRL changes.

## Usage

```hcl
module "openvpn" {
  source = "../../modules/openvpn"

  name               = "studio-dev"
  vpc_id             = module.network.vpc_id
  vpc_cidr           = module.network.vpc_cidr
  subnet_ids         = module.network.vpn_subnet_ids
  runtime_secret_arn = var.openvpn_runtime_secret_arn

  # Defaults to the VPC CIDR when omitted.
  allowed_routes = [module.network.vpc_cidr]
  ingress_cidrs  = ["0.0.0.0/0"]

  route53_zone_id     = data.aws_route53_zone.public.zone_id
  route53_record_name = "vpn.example.com"
}
```

Public subnets need a default route to an internet gateway. Restrict
`ingress_cidrs` when employee egress addresses are predictable. If the secret
uses a customer-managed KMS key, also set `runtime_secret_kms_key_arn`.
