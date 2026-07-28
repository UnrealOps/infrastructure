data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_ami" "ubuntu" {
  count = var.ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  asg_name            = "${var.name}-openvpn"
  lifecycle_hook_name = "${var.name}-openvpn-ready"
  dns_server          = coalesce(var.dns_server, cidrhost(var.vpc_cidr, 2))
  allowed_routes      = var.allowed_routes == null ? [var.vpc_cidr] : var.allowed_routes
  ami_id              = coalesce(var.ami_id, try(data.aws_ami.ubuntu[0].id, null))

  route_pushes = join("\n", [
    for cidr in local.allowed_routes : "push \"route ${cidrhost(cidr, 0)} ${cidrnetmask(cidr)}\""
  ])
  nft_forward_rules = join("\n", [
    for cidr in local.allowed_routes : "    iifname \"tun0\" oifname \"$PRIMARY_INTERFACE\" ip saddr $CLIENT_CIDR ip daddr ${cidrhost(cidr, 0)}/${split("/", cidr)[1]} ct state { new, established, related } accept"
  ])
  nft_return_rules = join("\n", [
    for cidr in local.allowed_routes : "    iifname \"$PRIMARY_INTERFACE\" oifname \"tun0\" ip saddr ${cidrhost(cidr, 0)}/${split("/", cidr)[1]} ip daddr $CLIENT_CIDR ct state { established, related } accept"
  ])
  nft_nat_rules = join("\n", [
    for cidr in local.allowed_routes : "    oifname \"$PRIMARY_INTERFACE\" ip saddr $CLIENT_CIDR ip daddr ${cidrhost(cidr, 0)}/${split("/", cidr)[1]} masquerade"
  ])

  client_range_start = sum([
    for index, octet in split(".", cidrhost(var.client_cidr, 0)) : parseint(octet, 10) * pow(256, 3 - index)
  ])
  client_range_end = local.client_range_start + pow(2, 32 - parseint(split("/", var.client_cidr)[1], 10)) - 1
  protected_route_ranges = [
    for cidr in distinct(concat(local.allowed_routes, [var.vpc_cidr])) : {
      start = sum([
        for index, octet in split(".", cidrhost(cidr, 0)) : parseint(octet, 10) * pow(256, 3 - index)
      ])
      end = sum([
        for index, octet in split(".", cidrhost(cidr, 0)) : parseint(octet, 10) * pow(256, 3 - index)
      ]) + pow(2, 32 - parseint(split("/", cidr)[1], 10)) - 1
    }
  ]
  allowed_route_ranges = [
    for cidr in local.allowed_routes : {
      start = sum([
        for index, octet in split(".", cidrhost(cidr, 0)) : parseint(octet, 10) * pow(256, 3 - index)
      ])
      end = sum([
        for index, octet in split(".", cidrhost(cidr, 0)) : parseint(octet, 10) * pow(256, 3 - index)
      ]) + pow(2, 32 - parseint(split("/", cidr)[1], 10)) - 1
    }
  ]
  dns_address = try(sum([
    for index, octet in split(".", local.dns_server) : parseint(octet, 10) * pow(256, 3 - index)
  ]), -1)

  asg_arn = "arn:${data.aws_partition.current.partition}:autoscaling:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${local.asg_name}"

  tags = merge(var.tags, {
    Module = "openvpn"
  })
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/unrealops/${var.name}/openvpn"
  retention_in_days = var.log_retention_days

  tags = merge(local.tags, {
    Name = "${var.name}-openvpn"
  })
}

resource "aws_eip" "this" {
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${var.name}-openvpn"
  })
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-openvpn-"
  description = "OpenVPN Community appliance; administration is through SSM only"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, {
    Name = "${var.name}-openvpn"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "openvpn" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "OpenVPN UDP from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = var.port
  to_port           = var.port
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "allowed_routes" {
  for_each = toset(local.allowed_routes)

  security_group_id = aws_security_group.this.id
  description       = "VPN client traffic to ${each.value}"
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
}

# Ubuntu, OpenVPN, and AWS publish signed artifacts behind DNS names with
# changing public addresses. A static CIDR allowlist would prevent reliable
# replacement-instance bootstrap; review this exception annually.
#trivy:ignore:AVD-AWS-0104:exp:2027-07-16
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS for AWS APIs and signed package repositories"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  security_group_id = aws_security_group.this.id
  description       = "DNS to the configured resolver"
  cidr_ipv4         = "${local.dns_server}/32"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  security_group_id = aws_security_group.this.id
  description       = "DNS fallback to the configured resolver"
  cidr_ipv4         = "${local.dns_server}/32"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "ntp" {
  security_group_id = aws_security_group.this.id
  description       = "NTP to the Amazon Time Sync Service"
  cidr_ipv4         = "169.254.169.123/32"
  from_port         = 123
  to_port           = 123
  ip_protocol       = "udp"
}

resource "aws_launch_template" "this" {
  name_prefix             = "${var.name}-openvpn-"
  description             = "Self-healing OpenVPN Community Edition appliance"
  image_id                = local.ami_id
  instance_type           = var.instance_type
  update_default_version  = true
  disable_api_stop        = false
  disable_api_termination = false

  # EC2 accepts 16 KiB of decoded user data. Cloud-init transparently expands
  # gzip content, leaving room for several caller-supplied split-tunnel routes.
  user_data = base64gzip(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    allocation_id              = aws_eip.this.allocation_id
    asg_name                   = local.asg_name
    client_cidr                = "${cidrhost(var.client_cidr, 0)}/${split("/", var.client_cidr)[1]}"
    client_netmask             = cidrnetmask(var.client_cidr)
    client_network             = cidrhost(var.client_cidr, 0)
    dns_server                 = local.dns_server
    lifecycle_hook_name        = local.lifecycle_hook_name
    log_group_name             = aws_cloudwatch_log_group.this.name
    nft_forward_rules          = local.nft_forward_rules
    nft_nat_rules              = local.nft_nat_rules
    nft_return_rules           = local.nft_return_rules
    openvpn_package_version    = "2.7.5-noble1"
    port                       = var.port
    region                     = data.aws_region.current.region
    route_pushes               = local.route_pushes
    runtime_secret_arn         = var.runtime_secret_arn
    watchdog_failure_threshold = var.watchdog_failure_threshold
  }))

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      delete_on_termination = true
      encrypted             = true
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
    }
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.this.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = 1
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }

  monitoring {
    enabled = true
  }

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    device_index                = 0
    security_groups             = [aws_security_group.this.id]
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(local.tags, {
      Name = "${var.name}-openvpn"
    })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(local.tags, {
      Name = "${var.name}-openvpn"
    })
  }

  tags = merge(local.tags, {
    Name = "${var.name}-openvpn"
  })

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_iam_role_policy.instance,
    aws_iam_role_policy_attachment.ssm,
  ]
}

resource "aws_autoscaling_group" "this" {
  name                      = local.asg_name
  desired_capacity          = 1
  min_size                  = 1
  max_size                  = 1
  health_check_grace_period = 600
  health_check_type         = "EC2"
  default_cooldown          = 180
  vpc_zone_identifier       = var.subnet_ids
  wait_for_capacity_timeout = "15m"

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  initial_lifecycle_hook {
    name                 = local.lifecycle_hook_name
    default_result       = "ABANDON"
    heartbeat_timeout    = 900
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      instance_warmup        = 600
      min_healthy_percentage = 0
      max_healthy_percentage = 100
    }
  }

  dynamic "tag" {
    for_each = merge(local.tags, {
      Name = "${var.name}-openvpn"
    })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    precondition {
      condition = (
        (var.route53_zone_id == null && var.route53_record_name == null) ||
        (var.route53_zone_id != null && var.route53_record_name != null)
      )
      error_message = "route53_zone_id and route53_record_name must be set together."
    }

    precondition {
      condition = alltrue([
        for route in local.protected_route_ranges :
        local.client_range_end < route.start || route.end < local.client_range_start
      ])
      error_message = "client_cidr must not overlap vpc_cidr or any allowed_routes CIDR."
    }

    precondition {
      condition = anytrue([
        for route in local.allowed_route_ranges :
        route.start <= local.dns_address && local.dns_address <= route.end
      ])
      error_message = "dns_server must be contained by at least one allowed_routes CIDR."
    }
  }

  depends_on = [
    aws_vpc_security_group_ingress_rule.openvpn,
    aws_vpc_security_group_egress_rule.allowed_routes,
    aws_vpc_security_group_egress_rule.dns_tcp,
    aws_vpc_security_group_egress_rule.dns_udp,
    aws_vpc_security_group_egress_rule.https,
    aws_vpc_security_group_egress_rule.ntp,
  ]
}

resource "aws_route53_record" "this" {
  count = var.route53_zone_id != null && var.route53_record_name != null ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.route53_record_name
  type    = "A"
  ttl     = 60
  records = [aws_eip.this.public_ip]
}
