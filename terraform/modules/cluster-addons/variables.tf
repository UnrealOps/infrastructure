variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string

  validation {
    condition     = length(var.cluster_name) > 0
    error_message = "cluster_name must not be empty."
  }
}

variable "cluster_endpoint" {
  description = "Private Kubernetes API endpoint exposed by the EKS module."
  type        = string

  validation {
    condition     = can(regex("^https://", var.cluster_endpoint))
    error_message = "cluster_endpoint must be an HTTPS URL."
  }
}

variable "node_iam_role_name" {
  description = "Name of the Karpenter node IAM role created by karpenter-infra."
  type        = string

  validation {
    condition     = length(var.node_iam_role_name) > 0
    error_message = "node_iam_role_name must not be empty."
  }
}

variable "interruption_queue_name" {
  description = "Name of the SQS interruption queue created by karpenter-infra."
  type        = string

  validation {
    condition     = length(var.interruption_queue_name) > 0
    error_message = "interruption_queue_name must not be empty."
  }
}

variable "discovery_tag_value" {
  description = "Value of the karpenter.sh/discovery tag on eligible subnets and the shared node security group. Defaults to cluster_name."
  type        = string
  default     = null
}

variable "namespace" {
  description = "Namespace in which to install Karpenter."
  type        = string
  default     = "kube-system"
}

variable "service_account" {
  description = "Service-account name associated with the Karpenter Pod Identity."
  type        = string
  default     = "karpenter"
}

variable "karpenter_version" {
  description = "Repository-tested Karpenter controller and CRD chart version."
  type        = string
  default     = "1.14.0"

  validation {
    condition     = var.karpenter_version == "1.14.0"
    error_message = "This module release supports only Karpenter 1.14.0."
  }
}

variable "controller_replicas" {
  description = "Number of Karpenter controller replicas placed on stable system nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.controller_replicas >= 2
    error_message = "controller_replicas must be at least two."
  }
}

variable "enable_spot_to_spot_consolidation" {
  description = "Enable Karpenter's alpha spot-to-spot consolidation feature gate."
  type        = bool
  default     = false
}

variable "additional_helm_values" {
  description = "Additional Karpenter controller values as YAML documents. Later documents override module defaults."
  type        = list(string)
  default     = []
}

variable "node_class_name" {
  description = "Name of the default EC2NodeClass."
  type        = string
  default     = "default"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.node_class_name)) && length(var.node_class_name) <= 63
    error_message = "node_class_name must be a valid DNS label of at most 63 characters."
  }
}

variable "node_pool_name" {
  description = "Name of the default general-purpose NodePool."
  type        = string
  default     = "general-purpose"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.node_pool_name)) && length(var.node_pool_name) <= 63
    error_message = "node_pool_name must be a valid DNS label of at most 63 characters."
  }
}

variable "ami_alias" {
  description = "Pinned AL2023 Karpenter AMI alias. The date matches the tested EKS 1.36 AL2023 release."
  type        = string
  default     = "al2023@v20260709"

  validation {
    condition     = var.ami_alias == "al2023@v20260709"
    error_message = "This module release has only been tested with al2023@v20260709."
  }
}

variable "architectures" {
  description = "CPU architectures allowed by the default NodePool."
  type        = list(string)
  default     = ["amd64"]

  validation {
    condition     = length(var.architectures) > 0 && alltrue([for value in var.architectures : contains(["amd64", "arm64"], value)])
    error_message = "architectures may contain amd64 and arm64."
  }
}

variable "capacity_types" {
  description = "Karpenter capacity types allowed by the default NodePool."
  type        = list(string)
  default     = ["spot", "on-demand"]

  validation {
    condition     = length(var.capacity_types) > 0 && alltrue([for value in var.capacity_types : contains(["spot", "on-demand", "reserved"], value)])
    error_message = "capacity_types may contain spot, on-demand, and reserved."
  }
}

variable "instance_categories" {
  description = "EC2 instance categories allowed by the default NodePool."
  type        = list(string)
  default     = ["c", "m", "r"]

  validation {
    condition     = length(var.instance_categories) > 0 && alltrue([for value in var.instance_categories : length(value) > 0])
    error_message = "instance_categories must contain at least one category."
  }
}

variable "minimum_instance_generation" {
  description = "Require EC2 instance generations greater than this value."
  type        = number
  default     = 5

  validation {
    condition     = var.minimum_instance_generation >= 2
    error_message = "minimum_instance_generation must be at least two."
  }
}

variable "node_pool_cpu_limit" {
  description = "Aggregate CPU limit for the default NodePool."
  type        = string
  default     = "1000"
}

variable "node_pool_memory_limit" {
  description = "Aggregate memory limit for the default NodePool."
  type        = string
  default     = "1000Gi"
}

variable "consolidation_policy" {
  description = "Karpenter disruption consolidation policy."
  type        = string
  default     = "WhenEmptyOrUnderutilized"

  validation {
    condition     = contains(["WhenEmpty", "WhenEmptyOrUnderutilized"], var.consolidation_policy)
    error_message = "consolidation_policy must be WhenEmpty or WhenEmptyOrUnderutilized."
  }
}

variable "consolidate_after" {
  description = "Delay before Karpenter considers a node for consolidation."
  type        = string
  default     = "1m"
}

variable "disruption_budget_nodes" {
  description = "Maximum nodes disrupted concurrently, expressed as a count or percentage."
  type        = string
  default     = "10%"

  validation {
    condition     = can(regex("^[0-9]+%?$", var.disruption_budget_nodes))
    error_message = "disruption_budget_nodes must be a count or percentage such as 1 or 10%."
  }
}

variable "expire_after" {
  description = "Maximum lifetime of Karpenter nodes."
  type        = string
  default     = "720h"
}

variable "termination_grace_period" {
  description = "Maximum graceful drain duration before Karpenter terminates a node."
  type        = string
  default     = "24h"
}

variable "node_pool_weight" {
  description = "Scheduling weight of the default NodePool."
  type        = number
  default     = 10
}

variable "root_volume_size" {
  description = "Root gp3 volume size in GiB for Karpenter nodes."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size >= 20
    error_message = "root_volume_size must be at least 20 GiB."
  }
}

variable "root_volume_kms_key_id" {
  description = "Optional KMS key ARN or ID for Karpenter node root volumes."
  type        = string
  default     = null
}

variable "node_labels" {
  description = "Additional labels applied to nodes created by the default NodePool."
  type        = map(string)
  default     = {}
}

variable "node_class_tags" {
  description = "Additional AWS tags applied to instances, volumes, and network interfaces created by Karpenter."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for key in keys(var.node_class_tags) :
      key != "" &&
      !startswith(key, "kubernetes.io/cluster") &&
      !contains([
        "eks:eks-cluster-name",
        "karpenter.sh/nodepool",
        "karpenter.sh/nodeclaim",
        "karpenter.k8s.aws/ec2nodeclass",
      ], key)
    ])
    error_message = "node_class_tags must use non-empty keys and must not set tags reserved and managed by Karpenter."
  }
}

variable "helm_timeout_seconds" {
  description = "Timeout for each Helm release operation."
  type        = number
  default     = 600

  validation {
    condition     = var.helm_timeout_seconds >= 300
    error_message = "helm_timeout_seconds must be at least 300 seconds."
  }
}
