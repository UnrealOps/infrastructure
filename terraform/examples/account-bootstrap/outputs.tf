output "eks_admin_role_arn" {
  description = "ARN of the role administrators assume before accessing EKS."
  value       = module.account_bootstrap.role_arn
}

output "admin_principal_arns" {
  description = "Copy this value into the complete foundation's admin_principal_arns input."
  value       = module.account_bootstrap.admin_principal_arns
}

output "trusted_principal_arns" {
  description = "Permanent IAM principals trusted to assume the administrator role. Review this output when implicit caller trust is used."
  value       = module.account_bootstrap.trusted_principal_arns
}

output "cluster_arns" {
  description = "EKS clusters that the role may describe."
  value       = module.account_bootstrap.cluster_arns
}
