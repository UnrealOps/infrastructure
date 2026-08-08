# Network Module

Creates the three-AZ VPC foundation for a private EKS cluster. Each AZ receives
a `/19` private worker subnet and `/24` public NAT gateway subnet. Three
separate `/28` public subnets host replaceable VPN appliances. The module also
creates one NAT gateway per AZ, CloudWatch VPC flow logs, S3 and DynamoDB
gateway endpoints on every private route table, and EKS/Karpenter discovery
tags.

## Usage

Configure the AWS provider in the calling root module; this module intentionally contains no provider configuration.

```hcl
module "network" {
  source = "../../modules/network"

  name         = "studio-prod"
  cluster_name = "studio-prod"

  tags = {
    Environment = "production"
    Project     = "unrealops"
  }
}
```

With the default `10.0.0.0/16` VPC, private subnets are `10.0.0.0/19`, `10.0.32.0/19`, and `10.0.64.0/19`; NAT subnets are `10.0.96.0/24` through `10.0.98.0/24`; VPN subnets begin at `10.0.99.0/28`.

Set `availability_zones` to exactly three zones to override automatic selection. Subnet overrides must likewise contain three canonical `/19`, `/24`, or `/28` CIDRs. Planning fails when an override is outside the VPC or overlaps another subnet.

The `vpn_source_prefix_list_id` output can be used in security-group rules for services reached through SNAT-enabled VPN appliances. `private_subnet_ids` are intended for EKS nodes and Karpenter capacity.

## Validation

```shell
tofu -chdir=terraform/modules/network init -backend=false
tofu -chdir=terraform/modules/network validate
tofu fmt -recursive -check terraform/modules/network
```
