variable "cluster_name" {
  description = "Name of the EKS cluster. Names are limited to 40 characters so derived IAM role names remain valid."
  type        = string

  validation {
    condition     = length(var.cluster_name) >= 1 && length(var.cluster_name) <= 40 && can(regex("^[A-Za-z0-9][A-Za-z0-9_-]*$", var.cluster_name))
    error_message = "cluster_name must be 1-40 characters and contain only letters, numbers, underscores, and hyphens."
  }
}

variable "vpc_id" {
  description = "ID of the VPC in which to create the cluster security groups."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a valid VPC ID."
  }
}

variable "private_subnet_ids" {
  description = "Private subnet IDs used by the managed node group and EKS control plane when control_plane_subnet_ids is empty."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2 && length(distinct(var.private_subnet_ids)) == length(var.private_subnet_ids) && alltrue([for id in var.private_subnet_ids : can(regex("^subnet-[0-9a-f]+$", id))])
    error_message = "private_subnet_ids must contain at least two distinct subnet IDs."
  }
}

variable "control_plane_subnet_ids" {
  description = "Optional dedicated subnet IDs for EKS control-plane ENIs. Defaults to private_subnet_ids."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.control_plane_subnet_ids) == 0 || (length(var.control_plane_subnet_ids) >= 2 && alltrue([for id in var.control_plane_subnet_ids : can(regex("^subnet-[0-9a-f]+$", id))]))
    error_message = "control_plane_subnet_ids must be empty or contain at least two subnet IDs."
  }
}

variable "vpn_cidr_blocks" {
  description = "IPv4 CIDRs allowed to reach the private Kubernetes API on TCP 443. With OpenVPN SNAT, pass the VPN appliance subnet CIDRs."
  type        = list(string)

  validation {
    condition     = length(var.vpn_cidr_blocks) > 0 && alltrue([for cidr in var.vpn_cidr_blocks : can(cidrnetmask(cidr))])
    error_message = "vpn_cidr_blocks must contain at least one valid IPv4 CIDR."
  }
}

variable "system_node_instance_types" {
  description = "On-demand instance types available to the system managed node group."
  type        = list(string)
  default     = ["m6i.large"]

  validation {
    condition     = length(var.system_node_instance_types) > 0 && alltrue([for instance_type in var.system_node_instance_types : length(instance_type) > 0])
    error_message = "system_node_instance_types must contain at least one instance type."
  }
}

variable "system_node_group_size" {
  description = "Scaling limits for the on-demand system managed node group."
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
    condition     = var.system_node_group_size.min >= 2 && var.system_node_group_size.min <= var.system_node_group_size.desired && var.system_node_group_size.desired <= var.system_node_group_size.max
    error_message = "system_node_group_size must keep at least two nodes and satisfy min <= desired <= max."
  }
}

variable "system_node_volume_size" {
  description = "Root gp3 volume size in GiB for system nodes."
  type        = number
  default     = 50

  validation {
    condition     = var.system_node_volume_size >= 20
    error_message = "system_node_volume_size must be at least 20 GiB."
  }
}

variable "system_node_volume_kms_key_id" {
  description = "Optional KMS key ARN or ID used to encrypt system-node root volumes. AWS-managed EBS encryption is used when null."
  type        = string
  default     = null
}

variable "access_entries" {
  description = "EKS access entries and associated cluster access policies."
  type = map(object({
    kubernetes_groups = optional(list(string))
    principal_arn     = string
    type              = optional(string, "STANDARD")
    user_name         = optional(string)
    tags              = optional(map(string), {})
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        namespaces = optional(list(string))
        type       = string
      })
    })), {})
  }))
  default = {}
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Grant the Terraform caller cluster-admin through an EKS access entry. Automatically suppressed when the caller already has a durable access_entries entry; otherwise disable after adding durable administrative access."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Protect the EKS cluster from accidental deletion. Enable for long-lived environments."
  type        = bool
  default     = false
}

variable "cloudwatch_log_retention_days" {
  description = "Retention period for EKS control-plane logs."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.cloudwatch_log_retention_days)
    error_message = "cloudwatch_log_retention_days must be a CloudWatch Logs-supported retention period."
  }
}

variable "enable_lore_observability" {
  description = "Install the pinned CloudWatch Observability add-on for Lore with OTel Container Insights and Pod Identity."
  type        = bool
  default     = false
}

variable "kms_key_administrators" {
  description = "IAM principal ARNs allowed to administer the EKS secrets-encryption KMS key. The Terraform caller is used when empty."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all supported resources."
  type        = map(string)
  default     = {}
}
