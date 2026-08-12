output "role_arn" {
  value = module.account_bootstrap.role_arn
}

output "role_name" {
  value = module.account_bootstrap.role_name
}

output "trusted_principal_arn" {
  value = one(module.account_bootstrap.trusted_principal_arns)
}

output "cluster_arn" {
  value = one(module.account_bootstrap.cluster_arns)
}
