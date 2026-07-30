output "ecr_repository_url" {
  description = "Private ECR repository URL for immutable Lore images."
  value       = aws_ecr_repository.lore.repository_url
}

output "endpoint_hostname" {
  description = "Private Lore endpoint hostname."
  value       = trimsuffix(aws_route53_zone.lore.name, ".")
}

output "bucket_name" {
  description = "S3 bucket containing durable Lore fragments."
  value       = aws_s3_bucket.fragments.id
}

output "table_names" {
  description = "Names of the four Lore DynamoDB tables."
  value       = local.table_names
}

output "hosted_zone_id" {
  description = "Private Route 53 hosted-zone ID for Lore."
  value       = aws_route53_zone.lore.zone_id
}

output "nlb_security_group_id" {
  description = "VPN-restricted frontend security group for the Lore NLB."
  value       = aws_security_group.lore_nlb.id
}

output "kms_key_arn" {
  description = "KMS key ARN used by Lore S3, DynamoDB, and telemetry logs."
  value       = aws_kms_key.lore.arn
}

output "runtime_secret_arn" {
  description = "ARN of the externally populated Lore runtime certificate secret."
  value       = data.aws_secretsmanager_secret.runtime.arn
}

output "pod_identity_role_arns" {
  description = "Lore Pod Identity role ARNs keyed by workload tier."
  value = {
    edge  = aws_iam_role.edge.arn
    write = aws_iam_role.write.arn
    otel  = aws_iam_role.otel.arn
  }
}

output "metrics_log_group_name" {
  description = "CloudWatch log group used by the ADOT embedded-metric exporter."
  value       = aws_cloudwatch_log_group.lore_metrics.name
}
