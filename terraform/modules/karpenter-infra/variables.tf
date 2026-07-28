variable "cluster_name" {
  description = "Name of the EKS cluster that Karpenter will manage."
  type        = string

  validation {
    condition     = length(var.cluster_name) >= 1 && length(var.cluster_name) <= 40 && can(regex("^[A-Za-z0-9][A-Za-z0-9_-]*$", var.cluster_name))
    error_message = "cluster_name must be 1-40 characters and contain only letters, numbers, underscores, and hyphens."
  }
}

variable "region" {
  description = "AWS region for Karpenter policies and interruption resources. Uses the configured AWS provider region when null."
  type        = string
  default     = null

  validation {
    condition     = var.region == null || can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must be a valid AWS region name."
  }
}

variable "namespace" {
  description = "Kubernetes namespace containing the Karpenter service account."
  type        = string
  default     = "kube-system"
}

variable "service_account" {
  description = "Karpenter controller service-account name."
  type        = string
  default     = "karpenter"
}

variable "enable_spot_termination" {
  description = "Create an encrypted SQS queue and EventBridge rules for interruption handling."
  type        = bool
  default     = true
}

variable "queue_kms_key_id" {
  description = "Optional customer-managed KMS key ID for the interruption queue. SQS-managed encryption is used when null."
  type        = string
  default     = null
}

variable "controller_permissions_boundary_arn" {
  description = "Optional permissions boundary ARN for the Karpenter controller IAM role."
  type        = string
  default     = null
}

variable "node_permissions_boundary_arn" {
  description = "Optional permissions boundary ARN for the Karpenter node IAM role."
  type        = string
  default     = null
}

variable "additional_controller_policy_arns" {
  description = "Additional managed IAM policies to attach to the Karpenter controller role."
  type        = map(string)
  default     = {}
}

variable "additional_node_policy_arns" {
  description = "Additional managed IAM policies for Karpenter nodes. SSM Session Manager access is included automatically."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to all supported resources."
  type        = map(string)
  default     = {}
}
