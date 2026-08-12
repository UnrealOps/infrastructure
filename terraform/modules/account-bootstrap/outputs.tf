output "role_arn" {
  description = "ARN of the durable IAM role to pass to the EKS foundation's admin_principal_arns input."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the durable EKS administrator IAM role."
  value       = aws_iam_role.this.name
}

output "role_path" {
  description = "IAM path of the durable EKS administrator role."
  value       = aws_iam_role.this.path
}

output "admin_principal_arns" {
  description = "Convenience value that can be copied directly into the EKS foundation input of the same name."
  value       = toset([aws_iam_role.this.arn])
}

output "trusted_principal_arns" {
  description = "Permanent IAM principals trusted to assume the administrator role."
  value       = var.trusted_principal_arns
}

output "cluster_arns" {
  description = "EKS cluster ARNs the role may describe."
  value       = local.cluster_arns
}
