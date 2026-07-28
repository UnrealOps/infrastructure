data "aws_partition" "current" {}

locals {
  controller_role_name = "${var.cluster_name}-karpenter-controller"
  node_role_name       = "${var.cluster_name}-karpenter-node"

  node_policy_arns = merge(
    {
      AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
    },
    var.additional_node_policy_arns,
  )
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.24.0"

  cluster_name = var.cluster_name
  region       = var.region

  iam_role_name                     = local.controller_role_name
  iam_role_use_name_prefix          = false
  enable_inline_policy              = true
  iam_role_permissions_boundary_arn = var.controller_permissions_boundary_arn
  iam_role_policies                 = var.additional_controller_policy_arns

  create_pod_identity_association = true
  namespace                       = var.namespace
  service_account                 = var.service_account

  enable_spot_termination   = var.enable_spot_termination
  queue_name                = "Karpenter-${var.cluster_name}"
  queue_managed_sse_enabled = var.queue_kms_key_id == null
  queue_kms_master_key_id   = var.queue_kms_key_id

  node_iam_role_name                     = local.node_role_name
  node_iam_role_use_name_prefix          = false
  node_iam_role_permissions_boundary     = var.node_permissions_boundary_arn
  node_iam_role_attach_cni_policy        = true
  node_iam_role_additional_policies      = local.node_policy_arns
  node_iam_role_source_account_condition = true

  create_access_entry     = true
  access_entry_type       = "EC2_LINUX"
  create_instance_profile = false

  tags = var.tags
}
