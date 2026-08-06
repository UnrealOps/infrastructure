data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_vpc" "this" {
  id = data.aws_eks_cluster.this.vpc_config[0].vpc_id
}

data "aws_ecr_repository" "lore" {
  name = "${var.cluster_name}/lore-server"
}

data "aws_s3_bucket" "fragments" {
  bucket = "${var.cluster_name}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}-lore-fragments"
}

data "aws_dynamodb_table" "fragments" {
  name = "${var.cluster_name}-lore-fragments"
}

data "aws_dynamodb_table" "fragment_metadata" {
  name = "${var.cluster_name}-lore-fragment-metadata"
}

data "aws_dynamodb_table" "mutable_store" {
  name = "${var.cluster_name}-lore-mutable-typed-store"
}

data "aws_dynamodb_table" "locks" {
  name = "${var.cluster_name}-lore-locks"
}

data "aws_secretsmanager_secret" "runtime" {
  name = local.runtime_secret_name
}

data "aws_route53_zone" "lore" {
  name         = "lore.${var.cluster_name}.internal."
  private_zone = true
}

data "aws_security_group" "lore_nlb" {
  name   = "${var.cluster_name}-lore-nlb"
  vpc_id = data.aws_vpc.this.id
}

data "aws_ec2_managed_prefix_list" "vpn_source" {
  name = "${var.cluster_name}-vpn-source"
}

data "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
}

locals {
  runtime_secret_name = coalesce(var.runtime_secret_name, "unrealops/${var.cluster_name}/lore/runtime")
  nlb_name            = substr("${var.cluster_name}-lore", 0, 32)
  endpoint_hostname   = "lore.${var.cluster_name}.internal"
  alarm_actions       = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
  lore_chart_version  = "0.1.0"

  common_tags = merge(var.tags, {
    ManagedBy             = "Terraform"
    "unrealops.io/module" = "lore-workload"
    "unrealops.io/lore"   = var.cluster_name
  })

  image_repository = split("@", var.image)[0]
}

resource "terraform_data" "validation" {
  input = {
    cluster_dependencies_ready = var.cluster_dependencies_ready
    image_repository           = local.image_repository
  }

  lifecycle {
    precondition {
      condition     = local.image_repository == data.aws_ecr_repository.lore.repository_url
      error_message = "image must use the deterministic Lore ECR repository created by the foundation root."
    }
  }
}

resource "kubernetes_namespace_v1" "lore" {
  metadata {
    name = "lore"
    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    }
  }
}

resource "helm_release" "lore" {
  name             = "lore"
  namespace        = "lore"
  create_namespace = false
  chart            = "${path.module}/charts/lore"

  atomic          = true
  cleanup_on_fail = true
  max_history     = 5
  timeout         = var.helm_timeout_seconds
  wait            = true
  wait_for_jobs   = true

  values = [yamlencode({
    clusterName = var.cluster_name
    aws = {
      region   = data.aws_region.current.region
      vpcCidr  = data.aws_vpc.this.cidr_block
      vpnCidrs = [for entry in data.aws_ec2_managed_prefix_list.vpn_source.entries : entry.cidr]
    }
    image             = var.image
    runtimeSecretName = data.aws_secretsmanager_secret.runtime.name
    nlb = {
      name            = local.nlb_name
      securityGroupId = data.aws_security_group.lore_nlb.id
    }
    storage = {
      bucketName             = data.aws_s3_bucket.fragments.id
      fragmentsTable         = data.aws_dynamodb_table.fragments.name
      fragmentMetadataTable  = data.aws_dynamodb_table.fragment_metadata.name
      mutableStoreTable      = data.aws_dynamodb_table.mutable_store.name
      locksTable             = data.aws_dynamodb_table.locks.name
      edgeCacheMaxSizeBytes  = var.edge_cache_max_size_bytes
      writeCacheMaxSizeBytes = 20000000000
    }
    edge = {
      replicas      = var.edge_replicas
      instanceTypes = var.edge_instance_types
      nodeRole      = data.aws_iam_role.karpenter_node.name
      amiAlias      = var.karpenter_ami_alias
    }
    write = {
      replicas = var.write_replicas
    }
    telemetry = {
      image = var.adot_image
    }
  })]

  depends_on = [terraform_data.validation, kubernetes_namespace_v1.lore]
}

data "aws_lb" "lore" {
  name = local.nlb_name

  depends_on = [helm_release.lore]
}

data "aws_lb_listener" "lore" {
  load_balancer_arn = data.aws_lb.lore.arn
  port              = 41337
}

locals {
  load_balancer_dimension = split("loadbalancer/", data.aws_lb.lore.arn)[1]
  target_group_arn        = data.aws_lb_listener.lore.default_action[0].target_group_arn
  target_group_dimension  = split(":", local.target_group_arn)[5]
}

resource "aws_route53_record" "lore" {
  zone_id = data.aws_route53_zone.lore.zone_id
  name    = data.aws_route53_zone.lore.name
  type    = "A"

  alias {
    name                   = data.aws_lb.lore.dns_name
    zone_id                = data.aws_lb.lore.zone_id
    evaluate_target_health = true
  }
}

resource "aws_cloudwatch_dashboard" "lore" {
  dashboard_name = "${var.cluster_name}-lore"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Lore NLB target health"
          region = data.aws_region.current.region
          view   = "timeSeries"
          metrics = [
            ["AWS/NetworkELB", "HealthyHostCount", "TargetGroup", local.target_group_dimension, "LoadBalancer", local.load_balancer_dimension],
            [".", "UnHealthyHostCount", ".", ".", ".", "."],
          ]
        }
      },
      {
        type   = "chart"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Lore workload availability and restarts (OTel Container Insights)"
          region = data.aws_region.current.region
          view   = "line"
          data = {
            queries = [
              {
                id       = "available"
                type     = "cloudwatch-metrics"
                language = "PromQL"
                query    = "kube_deployment_status_replicas_available{namespace=\"lore\",deployment=~\"lore-(edge|write)\"}"
                label    = "__verbose__"
              },
              {
                id       = "restarts"
                type     = "cloudwatch-metrics"
                language = "PromQL"
                query    = "sum(increase(kube_pod_container_status_restarts_total{namespace=\"lore\",container=\"lore\"}[5m]))"
                label    = "Lore restarts / 5m"
              },
            ]
          }
        }
      },
      {
        type   = "chart"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Lore edge ephemeral storage (OTel Container Insights)"
          region = data.aws_region.current.region
          view   = "line"
          data = {
            queries = [{
              id       = "edge_storage"
              type     = "cloudwatch-metrics"
              language = "PromQL"
              query    = "max by (pod) (container_fs_usage_bytes{namespace=\"lore\",container=\"lore\",pod=~\"lore-edge-.*\"})"
              label    = "__verbose__"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Lore certificate lifetime"
          region = data.aws_region.current.region
          view   = "timeSeries"
          metrics = [
            ["UnrealOps/Lore", "lore_certificate_days_until_expiry", "cluster", var.cluster_name, "tier", "edge"],
            [".", ".", ".", ".", ".", "write"],
          ]
        }
      },
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${var.cluster_name}-lore-unhealthy-targets"
  alarm_description   = "One or more Lore NLB targets are unhealthy"
  namespace           = "AWS/NetworkELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    LoadBalancer = local.load_balancer_dimension
    TargetGroup  = local.target_group_dimension
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "unavailable_replicas" {
  for_each = {
    edge  = var.edge_replicas
    write = var.write_replicas
  }

  alarm_name        = "${var.cluster_name}-lore-${each.key}-unavailable"
  alarm_description = "Lore ${each.key} tier has fewer ready pods than requested"
  alarm_actions     = local.alarm_actions

  evaluation_interval = 60
  evaluation_criteria {
    promql_criteria {
      query           = "(max(kube_deployment_status_replicas_available{namespace=\"lore\",deployment=\"lore-${each.key}\"}) < ${each.value}) or (absent(kube_deployment_status_replicas_available{namespace=\"lore\",deployment=\"lore-${each.key}\"}) == 1)"
      pending_period  = 180
      recovery_period = 120
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "pod_restarts" {
  alarm_name        = "${var.cluster_name}-lore-pod-restarts"
  alarm_description = "Lore containers restarted during the last five minutes"
  alarm_actions     = local.alarm_actions

  evaluation_interval = 60
  evaluation_criteria {
    promql_criteria {
      query           = "sum(increase(kube_pod_container_status_restarts_total{namespace=\"lore\",container=\"lore\"}[5m])) > 0"
      pending_period  = 0
      recovery_period = 300
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "edge_ephemeral_storage" {
  alarm_name        = "${var.cluster_name}-lore-edge-ephemeral-storage"
  alarm_description = "Lore edge container filesystem usage exceeds 650 GB"
  alarm_actions     = local.alarm_actions

  evaluation_interval = 60
  evaluation_criteria {
    promql_criteria {
      query           = "max(container_fs_usage_bytes{namespace=\"lore\",container=\"lore\",pod=~\"lore-edge-.*\"}) > 650000000000"
      pending_period  = 300
      recovery_period = 300
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "certificate_expiry" {
  for_each = toset(["edge", "write"])

  alarm_name          = "${var.cluster_name}-lore-${each.value}-certificate-expiry"
  alarm_description   = "The Lore ${each.value} runtime certificate expires in fewer than 30 days"
  namespace           = "UnrealOps/Lore"
  metric_name         = "lore_certificate_days_until_expiry"
  statistic           = "Minimum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 30
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    cluster = var.cluster_name
    tier    = each.value
  }

  tags = local.common_tags
}
