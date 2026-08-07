variable "aws_region" {
  description = "AWS region in which to deploy the studio foundation."
  type        = string
}

variable "name" {
  description = "Lowercase environment and cluster name used for all resources."
  type        = string
  default     = "studio-dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.name))
    error_message = "name must be 3-30 lowercase alphanumeric or hyphen characters and start with a letter."
  }
}

variable "vpc_cidr" {
  description = "Canonical /16 VPC CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Optional three-zone override. The network module chooses the first three available zones when empty."
  type        = list(string)
  default     = []
}

variable "openvpn_runtime_secret_arn" {
  description = "Secrets Manager ARN created by scripts/openvpn-pki.sh init."
  type        = string
}

variable "openvpn_runtime_secret_kms_key_arn" {
  description = "Optional customer-managed KMS key encrypting the OpenVPN runtime secret."
  type        = string
  default     = null
}

variable "openvpn_ingress_cidrs" {
  description = "Public CIDRs allowed to initiate OpenVPN UDP connections."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "openvpn_instance_type" {
  description = "EC2 instance type for the single OpenVPN appliance."
  type        = string
  default     = "t3.small"
}

variable "system_node_instance_types" {
  description = "On-demand instance types available to the EKS system node group."
  type        = list(string)
  default     = ["m6i.large"]

  validation {
    condition     = length(var.system_node_instance_types) > 0 && alltrue([for instance_type in var.system_node_instance_types : length(instance_type) > 0])
    error_message = "system_node_instance_types must contain at least one instance type."
  }
}

variable "system_node_group_size" {
  description = "Minimum, desired, and maximum size of the on-demand EKS system node group."
  type = object({
    min     = number
    desired = number
    max     = number
  })
  default = {
    min     = 2
    desired = 2
    max     = 3
  }

  validation {
    condition = (
      var.system_node_group_size.min >= 2 &&
      var.system_node_group_size.min <= var.system_node_group_size.desired &&
      var.system_node_group_size.desired <= var.system_node_group_size.max &&
      alltrue([
        for size in values(var.system_node_group_size) : size == floor(size)
      ])
    )
    error_message = "system_node_group_size values must be whole numbers, keep at least two nodes, and satisfy min <= desired <= max."
  }
}

variable "openvpn_route53_zone_id" {
  description = "Optional public Route 53 hosted-zone ID for the VPN endpoint."
  type        = string
  default     = null
}

variable "openvpn_route53_record_name" {
  description = "Optional public DNS name for the VPN endpoint. Set with openvpn_route53_zone_id."
  type        = string
  default     = null
}

variable "admin_principal_arns" {
  description = "IAM role or user ARNs granted the AmazonEKSClusterAdminPolicy through access entries."
  type        = set(string)
  default     = []
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Temporarily grant the applying principal cluster-admin. Disable after durable admin_principal_arns are configured."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Protect the EKS cluster from accidental deletion."
  type        = bool
  default     = false
}

variable "enable_lore" {
  description = "Create the opt-in Lore foundation, controller IAM, and CloudWatch observability resources."
  type        = bool
  default     = false
}

variable "lore_runtime_secret_name" {
  description = "Lore runtime certificate secret name created by scripts/lore-pki.sh. Defaults to unrealops/<name>/lore/runtime."
  type        = string
  default     = null
}

variable "lore_deletion_protection" {
  description = "Protect Lore DynamoDB tables from accidental deletion."
  type        = bool
  default     = true
}

variable "lore_force_destroy" {
  description = "Allow deletion of non-empty Lore S3 and ECR resources. Enable only for ephemeral acceptance environments."
  type        = bool
  default     = false
}

variable "lore_alarm_topic_arn" {
  description = "Optional SNS topic ARN receiving Lore foundation alarms."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags applied to supported resources."
  type        = map(string)
  default     = {}
}
