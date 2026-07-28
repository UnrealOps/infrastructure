locals {
  discovery_tag_value = coalesce(var.discovery_tag_value, var.cluster_name)

  controller_values = {
    replicas  = var.controller_replicas
    dnsPolicy = "Default"

    serviceAccount = {
      create = true
      name   = var.service_account
    }

    nodeSelector = {
      "karpenter.sh/controller" = "true"
    }

    controller = {
      resources = {
        requests = {
          cpu    = "500m"
          memory = "512Mi"
        }
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }
    }

    settings = {
      clusterName       = var.cluster_name
      clusterEndpoint   = var.cluster_endpoint
      eksControlPlane   = true
      interruptionQueue = var.interruption_queue_name
      featureGates = {
        spotToSpotConsolidation = var.enable_spot_to_spot_consolidation
      }
    }
  }

  node_class_tags = merge(
    {
      Name                     = "${var.cluster_name}-${var.node_pool_name}"
      "karpenter.sh/discovery" = local.discovery_tag_value
    },
    var.node_class_tags,
  )
}

resource "helm_release" "karpenter_crds" {
  name             = "karpenter-crd"
  namespace        = var.namespace
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  version          = var.karpenter_version

  atomic          = true
  cleanup_on_fail = true
  max_history     = 5
  timeout         = var.helm_timeout_seconds
  wait            = true
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = var.namespace
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version

  atomic          = true
  cleanup_on_fail = true
  max_history     = 5
  skip_crds       = true
  timeout         = var.helm_timeout_seconds
  wait            = true

  values = concat(
    [yamlencode(local.controller_values)],
    var.additional_helm_values,
  )

  depends_on = [helm_release.karpenter_crds]
}

resource "helm_release" "karpenter_resources" {
  name      = "karpenter-resources"
  namespace = var.namespace
  chart     = "${path.module}/charts/karpenter-resources"

  atomic          = true
  cleanup_on_fail = true
  max_history     = 5
  timeout         = var.helm_timeout_seconds
  wait            = true

  values = [yamlencode({
    nodeClass = {
      name              = var.node_class_name
      role              = var.node_iam_role_name
      discoveryTagValue = local.discovery_tag_value
      amiAlias          = var.ami_alias
      rootVolumeSize    = var.root_volume_size
      rootVolumeKmsKey  = var.root_volume_kms_key_id
      tags              = local.node_class_tags
    }
    nodePool = {
      name                      = var.node_pool_name
      nodeClassName             = var.node_class_name
      architectures             = var.architectures
      capacityTypes             = var.capacity_types
      instanceCategories        = var.instance_categories
      minimumInstanceGeneration = var.minimum_instance_generation
      cpuLimit                  = var.node_pool_cpu_limit
      memoryLimit               = var.node_pool_memory_limit
      consolidationPolicy       = var.consolidation_policy
      consolidateAfter          = var.consolidate_after
      disruptionBudgetNodes     = var.disruption_budget_nodes
      expireAfter               = var.expire_after
      terminationGracePeriod    = var.termination_grace_period
      weight                    = var.node_pool_weight
      labels = merge(
        { "unrealops.io/capacity-provider" = "karpenter" },
        var.node_labels,
      )
    }
  })]

  depends_on = [helm_release.karpenter]
}
