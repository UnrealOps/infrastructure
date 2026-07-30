output "availability_zones" {
  description = "Availability zones used by the network."
  value       = local.azs
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "IPv4 CIDR of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private EKS worker subnet IDs, ordered by availability_zones."
  value       = module.vpc.private_subnets
}

output "private_subnet_cidrs" {
  description = "Private EKS worker subnet CIDRs, ordered by availability_zones."
  value       = local.private_subnet_cidrs
}

output "public_subnet_ids" {
  description = "Public NAT gateway subnet IDs, ordered by availability_zones."
  value       = module.vpc.public_subnets
}

output "public_subnet_cidrs" {
  description = "Public NAT gateway subnet CIDRs, ordered by availability_zones."
  value       = local.public_subnet_cidrs
}

output "vpn_subnet_ids" {
  description = "Public VPN appliance subnet IDs, ordered by availability_zones."
  value       = [for az in local.azs : aws_subnet.vpn[az].id]
}

output "vpn_subnet_cidrs" {
  description = "Public VPN appliance subnet CIDRs, ordered by availability_zones."
  value       = local.vpn_subnet_cidrs
}

output "internet_gateway_id" {
  description = "ID of the VPC internet gateway used by public and VPN routes."
  value       = module.vpc.igw_id
}

output "private_route_table_ids" {
  description = "Private route table IDs, ordered by availability_zones."
  value       = module.vpc.private_route_table_ids
}

output "public_route_table_ids" {
  description = "Public NAT subnet route table IDs, ordered by availability_zones."
  value       = module.vpc.public_route_table_ids
}

output "vpn_route_table_ids" {
  description = "VPN appliance route table IDs, ordered by availability_zones."
  value       = [for az in local.azs : aws_route_table.vpn[az].id]
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs, ordered by availability_zones."
  value       = module.vpc.natgw_ids
}

output "nat_gateway_eip_allocation_ids" {
  description = "Allocation IDs for NAT gateway Elastic IP addresses."
  value       = module.vpc.nat_ids
}

output "nat_gateway_public_ips" {
  description = "Public IP addresses assigned to NAT gateways."
  value       = module.vpc.nat_public_ips
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint associated with private route tables."
  value       = module.gateway_endpoints.endpoints["s3"].id
}

output "dynamodb_gateway_endpoint_id" {
  description = "ID of the DynamoDB gateway VPC endpoint associated with private route tables."
  value       = module.gateway_endpoints.endpoints["dynamodb"].id
}

output "vpn_source_prefix_list_id" {
  description = "Customer-managed prefix list containing VPN appliance subnet CIDRs."
  value       = aws_ec2_managed_prefix_list.vpn_source.id
}
