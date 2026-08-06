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

resource "terraform_data" "lore_dependencies_validation" {
  input = var.enable_lore_dependencies

  lifecycle {
    precondition {
      condition     = !var.enable_lore_dependencies || (var.aws_region != null && length(var.aws_region) > 0)
      error_message = "aws_region is required when enable_lore_dependencies is true."
    }

    precondition {
      condition     = !var.enable_lore_dependencies || (var.vpc_id != null && length(var.vpc_id) > 0)
      error_message = "vpc_id is required when enable_lore_dependencies is true."
    }
  }
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

resource "helm_release" "aws_load_balancer_controller" {
  count = var.enable_lore_dependencies ? 1 : 0

  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_load_balancer_controller_version

  atomic          = true
  cleanup_on_fail = true
  max_history     = 5
  timeout         = var.helm_timeout_seconds
  wait            = true

  values = [yamlencode({
    clusterName  = var.cluster_name
    region       = var.aws_region
    vpcId        = var.vpc_id
    replicaCount = 2
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
    podDisruptionBudget = {
      maxUnavailable = 1
    }
    enableServiceMutatorWebhook = true
  })]

  depends_on = [
    helm_release.karpenter,
    terraform_data.lore_dependencies_validation,
  ]
}

resource "helm_release" "secrets_store_csi_driver" {
  count = var.enable_lore_dependencies ? 1 : 0

  name       = "secrets-store-csi-driver"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  version    = var.secrets_store_csi_driver_version

  atomic          = true
  cleanup_on_fail = true
  max_history     = 5
  timeout         = var.helm_timeout_seconds
  wait            = true

  values = [yamlencode({
    tokenRequests = [
      { audience = "sts.amazonaws.com" },
      { audience = "pods.eks.amazonaws.com" },
    ]
    syncSecret = {
      enabled = false
    }
    enableSecretRotation = false
  })]

  depends_on = [
    helm_release.karpenter,
    terraform_data.lore_dependencies_validation,
  ]
}

resource "helm_release" "secrets_store_csi_provider_aws" {
  count = var.enable_lore_dependencies ? 1 : 0

  name       = "secrets-store-csi-driver-provider-aws"
  namespace  = "kube-system"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  version    = var.secrets_store_csi_provider_aws_version

  atomic          = true
  cleanup_on_fail = true
  max_history     = 5
  timeout         = var.helm_timeout_seconds
  wait            = true

  values = [yamlencode({
    awsRegion = var.aws_region
    tolerations = [
      {
        key      = "unrealops.io/lore-edge"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      },
    ]
    secrets-store-csi-driver = {
      install = false
    }
  })]

  depends_on = [
    helm_release.secrets_store_csi_driver,
    terraform_data.lore_dependencies_validation,
  ]
}
