output "endpoint" {
  description = "OpenVPN hostname when Route 53 is configured, otherwise the stable Elastic IP."
  value       = var.route53_record_name != null ? trimsuffix(aws_route53_record.this[0].fqdn, ".") : aws_eip.this.public_ip
}

output "eip" {
  description = "Stable public Elastic IP associated with the healthy OpenVPN instance."
  value       = aws_eip.this.public_ip
}

output "eip_allocation_id" {
  description = "Allocation ID of the stable OpenVPN Elastic IP."
  value       = aws_eip.this.allocation_id
}

output "autoscaling_group_name" {
  description = "Name of the single-instance, self-healing OpenVPN Auto Scaling group."
  value       = aws_autoscaling_group.this.name
}

output "security_group_id" {
  description = "Security group attached to the OpenVPN appliance."
  value       = aws_security_group.this.id
}

output "log_group_name" {
  description = "CloudWatch log group receiving bootstrap and OpenVPN logs."
  value       = aws_cloudwatch_log_group.this.name
}
