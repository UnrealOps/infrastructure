output "controller_role_name" {
  description = "Name of the Karpenter controller Pod Identity role."
  value       = module.karpenter.iam_role_name
}

output "controller_role_arn" {
  description = "ARN of the Karpenter controller Pod Identity role."
  value       = module.karpenter.iam_role_arn
}

output "node_iam_role_name" {
  description = "IAM role name to configure in the Karpenter EC2NodeClass."
  value       = module.karpenter.node_iam_role_name
}

output "node_iam_role_arn" {
  description = "ARN of the role assumed by Karpenter-provisioned EC2 nodes."
  value       = module.karpenter.node_iam_role_arn
}

output "node_access_entry_arn" {
  description = "ARN of the EC2_LINUX EKS access entry for Karpenter nodes."
  value       = module.karpenter.node_access_entry_arn
}

output "interruption_queue_name" {
  description = "SQS queue name passed to the Karpenter Helm chart."
  value       = module.karpenter.queue_name
}

output "interruption_queue_arn" {
  description = "ARN of the Karpenter interruption queue."
  value       = module.karpenter.queue_arn
}

output "namespace" {
  description = "Namespace associated with Karpenter Pod Identity."
  value       = module.karpenter.namespace
}

output "service_account" {
  description = "Service account associated with Karpenter Pod Identity."
  value       = module.karpenter.service_account
}
