variable "cluster_name" {
  description = "EKS cluster name used in deterministic Lore resource names and Pod Identity associations."
  type        = string

  validation {
    condition     = length(var.cluster_name) >= 3 && length(var.cluster_name) <= 30 && can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-30 lowercase alphanumeric or hyphen characters and start with a letter."
  }
}

variable "vpc_id" {
  description = "VPC associated with the Lore private hosted zone and NLB security group."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR used to restrict NLB egress to Lore pod ports."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR."
  }
}

variable "vpn_source_prefix_list_id" {
  description = "Customer-managed prefix list containing the OpenVPN appliance source subnets."
  type        = string
}

variable "runtime_secret_name" {
  description = "Deterministic Secrets Manager name populated by scripts/lore-pki.sh."
  type        = string
}

variable "deletion_protection" {
  description = "Protect Lore DynamoDB tables from accidental deletion."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Allow Terraform to delete non-empty Lore S3 and ECR resources. Use only in ephemeral acceptance environments."
  type        = bool
  default     = false
}

variable "alarm_topic_arn" {
  description = "Optional SNS topic ARN receiving Lore foundation alarms."
  type        = string
  default     = null
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary ARN for Lore Pod Identity roles."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to Lore AWS resources."
  type        = map(string)
  default     = {}
}
