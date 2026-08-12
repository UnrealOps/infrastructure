variable "aws_region" {
  description = "AWS region containing the EKS clusters named in cluster_names."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region name."
  }
}

variable "cluster_names" {
  description = "EKS cluster names that administrators using this role may discover."
  type        = set(string)

  validation {
    condition = length(var.cluster_names) > 0 && alltrue([
      for name in var.cluster_names : length(name) <= 100 && can(regex("^[0-9A-Za-z][0-9A-Za-z_-]*$", name))
    ])
    error_message = "cluster_names must contain at least one valid EKS cluster name."
  }
}

variable "trusted_principal_arns" {
  description = "Permanent IAM role or user ARNs allowed to assume the EKS administrator role. Empty trusts the permanent issuer behind the credentials applying this stack."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.trusted_principal_arns : can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):iam::[0-9]{12}:(role|user)/[A-Za-z0-9+=,.@_/-]+$",
        arn
      ))
    ])
    error_message = "trusted_principal_arns may contain only exact, permanent IAM role or user ARNs."
  }
}

variable "role_name" {
  description = "Name of the durable IAM role that administrators assume before accessing EKS."
  type        = string
  default     = "StudioEKSAdministrators"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.role_name))
    error_message = "role_name must be 1-64 characters using only IAM role-name characters."
  }
}

variable "role_path" {
  description = "IAM path for the administrator role."
  type        = string
  default     = "/unrealops/"

  validation {
    condition     = length(var.role_path) <= 512 && can(regex("^/[A-Za-z0-9+=,.@_/-]*/$", var.role_path))
    error_message = "role_path must begin and end with a slash and use IAM path characters."
  }
}

variable "max_session_duration" {
  description = "Maximum duration, in seconds, for assumed administrator sessions."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration == floor(var.max_session_duration) && var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be an integer between 3600 and 43200 seconds."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary ARN for the administrator role."
  type        = string
  default     = null

  validation {
    condition = var.permissions_boundary_arn == null || can(regex(
      "^arn:(aws|aws-us-gov|aws-cn):iam::[0-9]{12}:policy/[A-Za-z0-9+=,.@_/-]+$",
      var.permissions_boundary_arn
    ))
    error_message = "permissions_boundary_arn must be null or a valid IAM managed-policy ARN."
  }
}

variable "tags" {
  description = "Additional tags for the bootstrap resources."
  type        = map(string)
  default     = {}
}
