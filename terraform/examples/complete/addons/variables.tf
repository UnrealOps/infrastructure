variable "aws_region" {
  description = "AWS region containing the foundation cluster."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name. Must match the foundation root name (and therefore cluster_name) output."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-30 lowercase alphanumeric or hyphen characters and start with a letter."
  }
}

variable "tags" {
  description = "Custom, non-reserved tags propagated to Karpenter-created EC2 resources. Karpenter supplies ownership tags."
  type        = map(string)
  default     = {}
}
