output "karpenter_version" {
  description = "Installed Karpenter chart version."
  value       = var.karpenter_version
}

output "karpenter_release_name" {
  description = "Karpenter controller Helm release name."
  value       = helm_release.karpenter.name
}

output "karpenter_crd_release_name" {
  description = "Karpenter CRD Helm release name."
  value       = helm_release.karpenter_crds.name
}

output "node_class_name" {
  description = "Name of the managed EC2NodeClass."
  value       = var.node_class_name
}

output "node_pool_name" {
  description = "Name of the managed NodePool."
  value       = var.node_pool_name
}

output "ami_alias" {
  description = "Pinned AL2023 AMI alias selected by the EC2NodeClass."
  value       = var.ami_alias
}

output "aws_load_balancer_controller_version" {
  description = "Installed AWS Load Balancer Controller chart version, or null when Lore dependencies are disabled."
  value       = var.enable_lore_dependencies ? var.aws_load_balancer_controller_version : null
}

output "secrets_store_csi_driver_version" {
  description = "Installed Secrets Store CSI Driver chart version, or null when Lore dependencies are disabled."
  value       = var.enable_lore_dependencies ? var.secrets_store_csi_driver_version : null
}

output "secrets_store_csi_provider_aws_version" {
  description = "Installed AWS Secrets Store CSI provider chart version, or null when Lore dependencies are disabled."
  value       = var.enable_lore_dependencies ? var.secrets_store_csi_provider_aws_version : null
}

output "lore_dependencies_ready" {
  description = "Dependency token that becomes ready after every Lore cluster controller is installed."
  value       = var.enable_lore_dependencies

  depends_on = [
    helm_release.aws_load_balancer_controller,
    helm_release.secrets_store_csi_driver,
    helm_release.secrets_store_csi_provider_aws,
  ]
}
