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
