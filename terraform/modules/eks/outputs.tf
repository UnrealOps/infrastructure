output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded Kubernetes cluster CA data."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  description = "Pinned Kubernetes minor version."
  value       = module.eks.cluster_version
}

output "cluster_platform_version" {
  description = "AWS-managed EKS platform version."
  value       = module.eks.cluster_platform_version
}

output "cluster_security_group_id" {
  description = "ID of the additional EKS control-plane security group."
  value       = module.eks.cluster_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "ID of the primary security group created by EKS."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "Shared node security group selected by Karpenter discovery."
  value       = module.eks.node_security_group_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for Kubernetes secret encryption."
  value       = module.eks.kms_key_arn
}

output "cloudwatch_log_group_name" {
  description = "EKS control-plane log group name."
  value       = module.eks.cloudwatch_log_group_name
}

output "system_node_group" {
  description = "Attributes of the on-demand system managed node group."
  value       = module.eks.eks_managed_node_groups["system"]
}

output "cluster_addons" {
  description = "Attributes of the managed EKS add-ons."
  value       = module.eks.cluster_addons
}

output "cluster_addon_versions" {
  description = "Pinned add-on compatibility versions selected by this module release."
  value       = local.cluster_addon_versions
}

output "system_node_ami_release_version" {
  description = "Pinned AL2023 release used by the system managed node group."
  value       = local.system_node_ami_release_version
}

output "ebs_csi_pod_identity_role_arn" {
  description = "Pod Identity IAM role used by the EBS CSI controller."
  value       = aws_iam_role.ebs_csi.arn
}
