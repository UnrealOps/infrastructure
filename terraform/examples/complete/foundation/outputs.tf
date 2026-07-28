output "vpc_id" {
  description = "Studio VPC ID."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "Studio VPC CIDR."
  value       = module.network.vpc_cidr
}

output "private_subnet_ids" {
  description = "Private EKS and Karpenter subnet IDs."
  value       = module.network.private_subnet_ids
}

output "vpn_subnet_ids" {
  description = "Public VPN appliance subnet IDs."
  value       = module.network.vpn_subnet_ids
}

output "vpn_source_prefix_list_id" {
  description = "Prefix list for allowing SNATed traffic from VPN appliance subnets."
  value       = module.network.vpn_source_prefix_list_id
}

output "openvpn_endpoint" {
  description = "Stable OpenVPN IP address or configured DNS name."
  value       = module.openvpn.endpoint
}

output "openvpn_eip" {
  description = "Stable OpenVPN Elastic IP."
  value       = module.openvpn.eip
}

output "openvpn_autoscaling_group_name" {
  description = "OpenVPN Auto Scaling group used for failover tests and operations."
  value       = module.openvpn.autoscaling_group_name
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_version" {
  description = "Pinned EKS Kubernetes version."
  value       = module.eks.cluster_version
}

output "cluster_endpoint" {
  description = "Private EKS Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded EKS cluster CA for operator tooling. The add-ons root discovers this from AWS via data.aws_eks_cluster."
  value       = module.eks.cluster_certificate_authority_data
}

output "node_security_group_id" {
  description = "Shared node security group tagged for Karpenter discovery."
  value       = module.eks.node_security_group_id
}

output "cluster_addon_versions" {
  description = "Exact managed add-on versions requested from EKS."
  value       = module.eks.cluster_addon_versions
}

output "system_node_ami_release_version" {
  description = "Exact AL2023 release requested for the system node group."
  value       = module.eks.system_node_ami_release_version
}

output "cluster_kms_key_arn" {
  description = "KMS key ARN used for EKS secrets encryption and cleanup verification."
  value       = module.eks.kms_key_arn
}

output "karpenter_node_iam_role_name" {
  description = "Node role consumed by the Karpenter EC2NodeClass."
  value       = module.karpenter_infra.node_iam_role_name
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue consumed by the Karpenter controller."
  value       = module.karpenter_infra.interruption_queue_name
}
