variable "name" {
  description = "Name used for VPC resources and tags."
  type        = string
  default     = "unrealops"

  validation {
    condition = (
      length(var.name) >= 2 &&
      length(var.name) <= 64 &&
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.name))
    )
    error_message = "name must contain 2-64 lowercase alphanumeric characters or hyphens and cannot start or end with a hyphen."
  }
}

variable "cluster_name" {
  description = "EKS cluster name used for Kubernetes and Karpenter discovery tags."
  type        = string
  default     = "unrealops"

  validation {
    condition = (
      length(var.cluster_name) >= 2 &&
      length(var.cluster_name) <= 100 &&
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.cluster_name))
    )
    error_message = "cluster_name must contain 2-100 lowercase alphanumeric characters or hyphens and cannot start or end with a hyphen."
  }
}

variable "vpc_cidr" {
  description = "Canonical IPv4 /16 CIDR for the VPC. Subnet defaults are derived from this range."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition = alltrue([
      can(cidrnetmask(var.vpc_cidr)),
      can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/16$", var.vpc_cidr)),
      try(tonumber(split("/", var.vpc_cidr)[1]) == 16, false),
      try("${cidrhost(var.vpc_cidr, 0)}/16" == var.vpc_cidr, false),
    ])
    error_message = "vpc_cidr must be a canonical IPv4 /16 network such as 10.0.0.0/16."
  }
}

variable "availability_zones" {
  description = "Exactly three availability zones. An empty list selects the first three available zones in the provider region."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == 3
    error_message = "availability_zones must be empty or contain exactly three zones."
  }

  validation {
    condition     = length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones cannot contain duplicates."
  }
}

variable "private_subnet_cidrs" {
  description = "Optional three canonical /19 CIDRs for private EKS worker subnets."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.private_subnet_cidrs) == 0 || length(var.private_subnet_cidrs) == 3
    error_message = "private_subnet_cidrs must be empty or contain exactly three CIDRs."
  }

  validation {
    condition = alltrue([
      for cidr in var.private_subnet_cidrs : alltrue([
        can(cidrnetmask(cidr)),
        can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/19$", cidr)),
        try("${cidrhost(cidr, 0)}/19" == cidr, false),
      ])
    ])
    error_message = "Each private subnet CIDR must be a canonical IPv4 /19 network."
  }
}

variable "public_subnet_cidrs" {
  description = "Optional three canonical /24 CIDRs for public NAT gateway subnets."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.public_subnet_cidrs) == 0 || length(var.public_subnet_cidrs) == 3
    error_message = "public_subnet_cidrs must be empty or contain exactly three CIDRs."
  }

  validation {
    condition = alltrue([
      for cidr in var.public_subnet_cidrs : alltrue([
        can(cidrnetmask(cidr)),
        can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/24$", cidr)),
        try("${cidrhost(cidr, 0)}/24" == cidr, false),
      ])
    ])
    error_message = "Each public subnet CIDR must be a canonical IPv4 /24 network."
  }
}

variable "vpn_subnet_cidrs" {
  description = "Optional three canonical /28 CIDRs for public VPN appliance subnets."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.vpn_subnet_cidrs) == 0 || length(var.vpn_subnet_cidrs) == 3
    error_message = "vpn_subnet_cidrs must be empty or contain exactly three CIDRs."
  }

  validation {
    condition = alltrue([
      for cidr in var.vpn_subnet_cidrs : alltrue([
        can(cidrnetmask(cidr)),
        can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/28$", cidr)),
        try("${cidrhost(cidr, 0)}/28" == cidr, false),
      ])
    ])
    error_message = "Each VPN subnet CIDR must be a canonical IPv4 /28 network."
  }
}

variable "flow_log_retention_in_days" {
  description = "CloudWatch retention period for VPC flow logs."
  type        = number
  default     = 30

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731,
      1096, 1827, 2192, 2557, 2922, 3288, 3653,
    ], var.flow_log_retention_in_days)
    error_message = "flow_log_retention_in_days must be a retention period supported by CloudWatch Logs."
  }
}

variable "tags" {
  description = "Tags applied to all supported resources."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Additional tags for private EKS worker subnets. Required discovery tags cannot be overridden."
  type        = map(string)
  default     = {}
}

variable "public_subnet_tags" {
  description = "Additional tags for public NAT gateway subnets. Required EKS tags cannot be overridden."
  type        = map(string)
  default     = {}
}

variable "vpn_subnet_tags" {
  description = "Additional tags for VPN appliance subnets."
  type        = map(string)
  default     = {}
}
