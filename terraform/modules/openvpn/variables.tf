variable "name" {
  description = "Short environment name used to name OpenVPN resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.name))
    error_message = "name must be 3-30 lowercase alphanumeric or hyphen characters and start with a letter."
  }
}

variable "vpc_id" {
  description = "ID of the VPC that OpenVPN clients may reach."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be an AWS VPC ID."
  }
}

variable "vpc_cidr" {
  description = "Primary IPv4 CIDR of the VPC; used for DNS and egress restrictions."
  type        = string

  validation {
    condition = (
      can(cidrnetmask(var.vpc_cidr)) &&
      can(regex("/(1[6-9]|2[0-8])$", var.vpc_cidr))
    )
    error_message = "vpc_cidr must be a valid AWS VPC IPv4 CIDR with a /16 through /28 prefix."
  }
}

variable "subnet_ids" {
  description = "Dedicated public VPN subnet IDs. The ASG can replace the appliance in any supplied Availability Zone."
  type        = list(string)

  validation {
    condition = (
      length(var.subnet_ids) >= 2 &&
      length(var.subnet_ids) == length(distinct(var.subnet_ids)) &&
      alltrue([for id in var.subnet_ids : can(regex("^subnet-[0-9a-f]+$", id))])
    )
    error_message = "subnet_ids must contain at least two distinct AWS subnet IDs."
  }
}

variable "runtime_secret_arn" {
  description = "ARN of a pre-existing Secrets Manager secret containing the base64 runtime bundle documented in README.md."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:", var.runtime_secret_arn))
    error_message = "runtime_secret_arn must be a Secrets Manager secret ARN."
  }
}

variable "runtime_secret_kms_key_arn" {
  description = "Customer-managed KMS key ARN used by the runtime secret, or null for the AWS-managed Secrets Manager key."
  type        = string
  default     = null

  validation {
    condition = (
      var.runtime_secret_kms_key_arn == null ||
      can(regex("^arn:[^:]+:kms:[^:]+:[0-9]{12}:key/", var.runtime_secret_kms_key_arn))
    )
    error_message = "runtime_secret_kms_key_arn must be null or a KMS key ARN."
  }
}

variable "client_cidr" {
  description = "Non-overlapping IPv4 address pool assigned to OpenVPN clients."
  type        = string
  default     = "10.250.0.0/20"

  validation {
    condition = (
      can(cidrnetmask(var.client_cidr)) &&
      can(regex("/(1[6-9]|2[0-8])$", var.client_cidr))
    )
    error_message = "client_cidr must be an IPv4 CIDR with a /16 through /28 prefix."
  }
}

variable "allowed_routes" {
  description = "IPv4 CIDRs reachable by VPN clients. Null defaults to vpc_cidr; a default route is prohibited."
  type        = list(string)
  default     = null

  validation {
    condition = var.allowed_routes == null ? true : (
      length(var.allowed_routes) > 0 && alltrue([
        for cidr in var.allowed_routes : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"
      ])
    )
    error_message = "allowed_routes must contain valid IPv4 CIDRs and cannot contain 0.0.0.0/0."
  }
}

variable "dns_server" {
  description = "DNS server pushed to clients. Defaults to the VPC resolver and must fall within an allowed_routes CIDR."
  type        = string
  default     = null

  validation {
    condition     = var.dns_server == null || can(cidrnetmask("${var.dns_server}/32"))
    error_message = "dns_server must be null or an IPv4 address."
  }
}

variable "port" {
  description = "UDP port exposed by the OpenVPN server."
  type        = number
  default     = 1194

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be an integer between 1 and 65535."
  }
}

variable "ingress_cidrs" {
  description = "Public IPv4 CIDRs permitted to initiate OpenVPN connections. Use narrow ranges when employee egress addresses are stable."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition = (
      length(var.ingress_cidrs) > 0 &&
      alltrue([for cidr in var.ingress_cidrs : can(cidrnetmask(cidr))])
    )
    error_message = "ingress_cidrs must contain at least one valid IPv4 CIDR."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the single OpenVPN appliance."
  type        = string
  default     = "t3.small"

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must be a valid EC2 instance type name."
  }
}

variable "ami_id" {
  description = "Optional Ubuntu 24.04 amd64 AMI override. The latest Canonical AMI is selected when null."
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must be null or an AWS AMI ID."
  }
}

variable "root_volume_size" {
  description = "Encrypted gp3 root volume size in GiB."
  type        = number
  default     = 16

  validation {
    condition = (
      var.root_volume_size >= 8 &&
      var.root_volume_size <= 16384 &&
      floor(var.root_volume_size) == var.root_volume_size
    )
    error_message = "root_volume_size must be an integer between 8 and 16384 GiB."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period."
  type        = number
  default     = 30

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731,
      1096, 1827, 2192, 2557, 2922, 3288, 3653,
    ], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch Logs supported retention value."
  }
}

variable "watchdog_failure_threshold" {
  description = "Consecutive one-minute OpenVPN health-check failures before the instance marks itself unhealthy."
  type        = number
  default     = 3

  validation {
    condition = (
      var.watchdog_failure_threshold >= 2 &&
      var.watchdog_failure_threshold <= 10 &&
      floor(var.watchdog_failure_threshold) == var.watchdog_failure_threshold
    )
    error_message = "watchdog_failure_threshold must be an integer between 2 and 10."
  }
}

variable "route53_zone_id" {
  description = "Optional Route 53 public hosted zone ID. Set with route53_record_name."
  type        = string
  default     = null
}

variable "route53_record_name" {
  description = "Optional Route 53 A-record name for the stable EIP. Set with route53_zone_id."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags applied to every supported resource."
  type        = map(string)
  default     = {}
}
