output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "vpn_subnet_ids" {
  value = module.network.vpn_subnet_ids
}

output "nat_gateway_ids" {
  value = module.network.nat_gateway_ids
}

output "vpn_source_prefix_list_id" {
  value = module.network.vpn_source_prefix_list_id
}
