variable "cluster_name" {
  description = "Name of the EKS cluster and deterministic Lore foundation resources."
  type        = string

  validation {
    condition     = length(var.cluster_name) >= 3 && length(var.cluster_name) <= 30 && can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-30 lowercase alphanumeric or hyphen characters and start with a letter."
  }
}

variable "image" {
  description = "Immutable private ECR Lore image URI."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9][a-z0-9/_-]*@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be a full private ECR URI ending in @sha256:<64 lowercase hexadecimal characters>."
  }
}

variable "runtime_secret_name" {
  description = "Optional Lore runtime secret name override. Defaults to unrealops/<cluster_name>/lore/runtime."
  type        = string
  default     = null
}

variable "edge_replicas" {
  description = "Number of NVMe-backed Lore edge replicas."
  type        = number
  default     = 3

  validation {
    condition     = var.edge_replicas >= 3
    error_message = "edge_replicas must be at least three."
  }
}

variable "write_replicas" {
  description = "Number of durable Lore write replicas."
  type        = number
  default     = 2

  validation {
    condition     = var.write_replicas >= 2
    error_message = "write_replicas must be at least two."
  }
}

variable "edge_instance_types" {
  description = "Arm64 instance types accepted by the dedicated Lore edge NodePool."
  type        = list(string)
  default     = ["c8gd.4xlarge"]

  validation {
    condition     = length(var.edge_instance_types) > 0 && alltrue([for instance_type in var.edge_instance_types : length(instance_type) > 0])
    error_message = "edge_instance_types must contain at least one EC2 instance type."
  }
}

variable "edge_cache_max_size_bytes" {
  description = "Maximum local immutable edge-cache size in bytes."
  type        = number
  default     = 700000000000

  validation {
    condition     = var.edge_cache_max_size_bytes > 0 && var.edge_cache_max_size_bytes <= 750000000000
    error_message = "edge_cache_max_size_bytes must be greater than zero and no more than the 750 GB ephemeral-storage allocation."
  }
}

variable "karpenter_ami_alias" {
  description = "Pinned AL2023 AMI alias shared with the repository-tested Karpenter configuration."
  type        = string
  default     = "al2023@v20260709"
}

variable "adot_image" {
  description = "Pinned AWS Distro for OpenTelemetry collector image."
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.48.0"

  validation {
    condition     = var.adot_image == "public.ecr.aws/aws-observability/aws-otel-collector:v0.48.0"
    error_message = "This module release supports only ADOT v0.48.0."
  }
}

variable "alarm_topic_arn" {
  description = "Optional SNS topic ARN receiving Lore workload alarms."
  type        = string
  default     = null
}

variable "helm_timeout_seconds" {
  description = "Timeout for the Lore Helm release and NLB readiness."
  type        = number
  default     = 1200

  validation {
    condition     = var.helm_timeout_seconds >= 600
    error_message = "helm_timeout_seconds must be at least 600 seconds."
  }
}

variable "tags" {
  description = "Tags applied to Terraform-managed Lore observability resources."
  type        = map(string)
  default     = {}
}
