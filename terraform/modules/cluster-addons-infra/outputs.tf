output "load_balancer_controller_role_arn" {
  description = "ARN of the AWS Load Balancer Controller Pod Identity role."
  value       = aws_iam_role.load_balancer_controller.arn
}

output "load_balancer_controller_policy_arn" {
  description = "ARN of the release-matched AWS Load Balancer Controller IAM policy."
  value       = aws_iam_policy.load_balancer_controller.arn
}

output "pod_identity_association_id" {
  description = "ID of the AWS Load Balancer Controller Pod Identity association."
  value       = aws_eks_pod_identity_association.load_balancer_controller.association_id
}
