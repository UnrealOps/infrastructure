variable "cluster_name" {
  description = "Name of the EKS cluster receiving the AWS Load Balancer Controller Pod Identity association."
  type        = string

  validation {
    condition     = length(var.cluster_name) >= 1 && length(var.cluster_name) <= 40 && can(regex("^[A-Za-z0-9][A-Za-z0-9_-]*$", var.cluster_name))
    error_message = "cluster_name must be 1-40 characters and contain only letters, numbers, underscores, and hyphens."
  }
}

variable "namespace" {
  description = "Kubernetes namespace containing the AWS Load Balancer Controller service account."
  type        = string
  default     = "kube-system"
}

variable "service_account" {
  description = "Kubernetes service account used by the AWS Load Balancer Controller."
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary ARN for the controller Pod Identity role."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to IAM resources."
  type        = map(string)
  default     = {}
}
