output "endpoint" {
  description = "VPN-only Lore client endpoint."
  value       = "lores://${local.endpoint_hostname}:41337"
}

output "nlb_name" {
  description = "Deterministic internal Lore NLB name."
  value       = data.aws_lb.lore.name
}

output "nlb_dns_name" {
  description = "AWS-generated internal Lore NLB DNS name."
  value       = data.aws_lb.lore.dns_name
}

output "deployed_image" {
  description = "Immutable Lore image URI deployed by Helm."
  value       = var.image
}

output "helm_release_name" {
  description = "Lore Helm release name."
  value       = helm_release.lore.name
}

output "helm_chart_version" {
  description = "Local Lore workload chart version."
  value       = local.lore_chart_version
}
