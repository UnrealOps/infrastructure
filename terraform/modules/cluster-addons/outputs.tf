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
