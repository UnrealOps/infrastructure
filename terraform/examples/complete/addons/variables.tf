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

variable "enable_lore" {
  description = "Deploy the full two-tier Lore workload and its pinned cluster dependencies."
  type        = bool
  default     = false
}

variable "lore_image" {
  description = "Immutable Lore ECR image URI. Required when enable_lore is true."
  type        = string
  default     = null

  validation {
    condition     = var.lore_image == null || try(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9][a-z0-9/_-]*@sha256:[0-9a-f]{64}$", var.lore_image) != "", false)
    error_message = "lore_image must be null or a full private ECR URI ending in @sha256:<64 lowercase hexadecimal characters>."
  }
}

variable "lore_runtime_secret_name" {
  description = "Optional Lore runtime secret name override. Defaults to unrealops/<cluster_name>/lore/runtime."
  type        = string
  default     = null
}

variable "lore_edge_replicas" {
  description = "Number of dedicated NVMe-backed Lore edge replicas."
  type        = number
  default     = 3
}

variable "lore_write_replicas" {
  description = "Number of durable Lore write replicas."
  type        = number
  default     = 2
}

variable "lore_edge_instance_types" {
  description = "Arm64 instance types accepted by the dedicated Lore edge NodePool."
  type        = list(string)
  default     = ["c8gd.4xlarge"]
}

variable "lore_edge_cache_max_size_bytes" {
  description = "Maximum local immutable edge-cache size in bytes."
  type        = number
  default     = 700000000000
}

variable "lore_alarm_topic_arn" {
  description = "Optional SNS topic ARN receiving Lore workload alarms."
  type        = string
  default     = null
}

variable "tags" {
  description = "Custom, non-reserved tags propagated to Karpenter-created EC2 resources. Karpenter supplies ownership tags."
  type        = map(string)
  default     = {}
}
