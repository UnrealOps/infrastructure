data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  cluster_arns = toset([
    for name in var.cluster_names : "arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:cluster/${name}"
  ])
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "TrustedAdministrators"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = sort(tolist(var.trusted_principal_arns))
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  path                 = var.role_path
  description          = "Durable administrator identity for UnrealOps EKS access entries"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary_arn

  tags = merge(var.tags, {
    Module = "account-bootstrap"
    Name   = var.role_name
  })
}

data "aws_iam_policy_document" "eks_discovery" {
  statement {
    sid       = "ListClusters"
    effect    = "Allow"
    actions   = ["eks:ListClusters"]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeNamedClusters"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = sort(tolist(local.cluster_arns))
  }
}

resource "aws_iam_role_policy" "eks_discovery" {
  name   = "${var.role_name}-eks-discovery"
  role   = aws_iam_role.this.name
  policy = data.aws_iam_policy_document.eks_discovery.json
}
