output "karpenter_version" {
  description = "Pinned Karpenter version installed in the cluster."
  value       = module.cluster_addons.karpenter_version
}

output "node_class_name" {
  description = "Default Karpenter EC2NodeClass."
  value       = module.cluster_addons.node_class_name
}

output "node_pool_name" {
  description = "Default general-purpose Karpenter NodePool."
  value       = module.cluster_addons.node_pool_name
}

output "lore_endpoint" {
  description = "VPN-only Lore client endpoint, or null when Lore is disabled."
  value       = try(module.lore_workload[0].endpoint, null)
}

output "lore_nlb_name" {
  description = "Internal Lore NLB name, or null when Lore is disabled."
  value       = try(module.lore_workload[0].nlb_name, null)
}

output "lore_nlb_dns_name" {
  description = "AWS-generated internal Lore NLB DNS name, or null when Lore is disabled."
  value       = try(module.lore_workload[0].nlb_dns_name, null)
}

output "lore_deployed_image" {
  description = "Immutable Lore image deployed to EKS, or null when Lore is disabled."
  value       = try(module.lore_workload[0].deployed_image, null)
}

output "lore_helm_release_versions" {
  description = "Pinned controller and workload Helm versions, or null when Lore is disabled."
  value = var.enable_lore ? {
    aws_load_balancer_controller = module.cluster_addons.aws_load_balancer_controller_version
    secrets_store_csi_driver     = module.cluster_addons.secrets_store_csi_driver_version
    secrets_store_provider_aws   = module.cluster_addons.secrets_store_csi_provider_aws_version
    lore                         = module.lore_workload[0].helm_chart_version
  } : null
}
