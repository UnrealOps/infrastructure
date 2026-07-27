output "endpoint" {
  value = module.openvpn.endpoint
}

output "eip" {
  value = module.openvpn.eip
}

output "autoscaling_group_name" {
  value = module.openvpn.autoscaling_group_name
}

output "security_group_id" {
  value = module.openvpn.security_group_id
}

output "log_group_name" {
  value = module.openvpn.log_group_name
}
