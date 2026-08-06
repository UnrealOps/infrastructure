data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_secretsmanager_secret" "runtime" {
  name = var.runtime_secret_name
}

locals {
  bucket_name_seed                 = "${var.cluster_name}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}-lore-fragments"
  bucket_cluster_prefix_max_length = 30 - length(data.aws_region.current.region)
  bucket_cluster_prefix            = substr(var.cluster_name, 0, min(length(var.cluster_name), local.bucket_cluster_prefix_max_length))
  bucket_name = length(local.bucket_name_seed) <= 63 ? local.bucket_name_seed : format(
    "%s-%s-%s-%s-fragments",
    local.bucket_cluster_prefix,
    data.aws_caller_identity.current.account_id,
    data.aws_region.current.region,
    substr(sha256(local.bucket_name_seed), 0, 8),
  )
  table_names = {
    fragments         = "${var.cluster_name}-lore-fragments"
    fragment_metadata = "${var.cluster_name}-lore-fragment-metadata"
    mutable_store     = "${var.cluster_name}-lore-mutable-typed-store"
    locks             = "${var.cluster_name}-lore-locks"
  }

  table_arns = {
    fragments         = aws_dynamodb_table.fragments.arn
    fragment_metadata = aws_dynamodb_table.fragment_metadata.arn
    mutable_store     = aws_dynamodb_table.mutable_store.arn
    locks             = aws_dynamodb_table.locks.arn
  }

  alarm_actions = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]

  common_tags = merge(var.tags, {
    ManagedBy             = "Terraform"
    "unrealops.io/module" = "lore-infra"
    "unrealops.io/lore"   = var.cluster_name
  })
}

resource "aws_kms_key" "lore" {
  description             = "Encrypts Lore fragments and DynamoDB tables for ${var.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = local.common_tags
}

resource "aws_kms_alias" "lore" {
  name          = "alias/${var.cluster_name}-lore"
  target_key_id = aws_kms_key.lore.key_id
}

resource "aws_ecr_repository" "lore" {
  name                 = "${var.cluster_name}/lore-server"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_destroy

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "lore" {
  repository = aws_ecr_repository.lore.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged build artifacts after seven days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Retain the twenty most recent published images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["0."]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}

resource "aws_s3_bucket" "fragments" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name = local.bucket_name
  })
}

resource "aws_s3_bucket_public_access_block" "fragments" {
  bucket = aws_s3_bucket.fragments.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "fragments" {
  bucket = aws_s3_bucket.fragments.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "fragments" {
  bucket = aws_s3_bucket.fragments.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "fragments" {
  bucket = aws_s3_bucket.fragments.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.lore.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "fragments" {
  bucket = aws_s3_bucket.fragments.id

  rule {
    id     = "lore-storage-hygiene"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.fragments]
}

data "aws_iam_policy_document" "fragments_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.fragments.arn,
      "${aws_s3_bucket.fragments.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "fragments" {
  bucket = aws_s3_bucket.fragments.id
  policy = data.aws_iam_policy_document.fragments_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.fragments]
}

resource "aws_dynamodb_table" "fragments" {
  name                        = local.table_names.fragments
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "hash"
  range_key                   = "repository_context"
  deletion_protection_enabled = var.deletion_protection

  attribute {
    name = "hash"
    type = "B"
  }

  attribute {
    name = "repository_context"
    type = "B"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.lore.arn
  }

  tags = local.common_tags
}

resource "aws_dynamodb_table" "fragment_metadata" {
  name                        = local.table_names.fragment_metadata
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "hash"
  deletion_protection_enabled = var.deletion_protection

  attribute {
    name = "hash"
    type = "B"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.lore.arn
  }

  tags = local.common_tags
}

resource "aws_dynamodb_table" "mutable_store" {
  name                        = local.table_names.mutable_store
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "repository_id"
  range_key                   = "key"
  deletion_protection_enabled = var.deletion_protection

  attribute {
    name = "repository_id"
    type = "B"
  }

  attribute {
    name = "key"
    type = "B"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.lore.arn
  }

  tags = local.common_tags
}

resource "aws_dynamodb_table" "locks" {
  name                        = local.table_names.locks
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "hash"
  range_key                   = "repositoryBranch"
  deletion_protection_enabled = var.deletion_protection

  attribute {
    name = "hash"
    type = "B"
  }

  attribute {
    name = "repositoryBranch"
    type = "B"
  }

  attribute {
    name = "ownerId"
    type = "S"
  }

  attribute {
    name = "repository"
    type = "B"
  }

  attribute {
    name = "branch"
    type = "B"
  }

  attribute {
    name = "description"
    type = "S"
  }

  global_secondary_index {
    name            = "owner-repo-branch"
    projection_type = "ALL"

    key_schema {
      attribute_name = "ownerId"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "repositoryBranch"
      key_type       = "RANGE"
    }
  }

  global_secondary_index {
    name            = "repo-branch"
    projection_type = "ALL"

    key_schema {
      attribute_name = "repository"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "branch"
      key_type       = "RANGE"
    }
  }

  global_secondary_index {
    name            = "repo-branch-description"
    projection_type = "ALL"

    key_schema {
      attribute_name = "repositoryBranch"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "description"
      key_type       = "RANGE"
    }
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.lore.arn
  }

  tags = local.common_tags
}

resource "aws_route53_zone" "lore" {
  name = "lore.${var.cluster_name}.internal"

  vpc {
    vpc_id = var.vpc_id
  }

  tags = local.common_tags
}

resource "aws_security_group" "lore_nlb" {
  name        = "${var.cluster_name}-lore-nlb"
  description = "VPN-only frontend security group for the internal Lore NLB"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-lore-nlb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "lore_tcp" {
  security_group_id = aws_security_group.lore_nlb.id
  description       = "Lore TLS gRPC from OpenVPN"
  prefix_list_id    = var.vpn_source_prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 41337
  to_port           = 41337
}

resource "aws_vpc_security_group_ingress_rule" "lore_udp" {
  security_group_id = aws_security_group.lore_nlb.id
  description       = "Lore TLS QUIC from OpenVPN"
  prefix_list_id    = var.vpn_source_prefix_list_id
  ip_protocol       = "udp"
  from_port         = 41337
  to_port           = 41337
}

resource "aws_vpc_security_group_egress_rule" "lore_tcp" {
  for_each = toset(["41337", "41339"])

  security_group_id = aws_security_group.lore_nlb.id
  description       = "Lore TCP ${each.value} to pods"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}

resource "aws_vpc_security_group_egress_rule" "lore_udp" {
  for_each = toset(["41337", "41340"])

  security_group_id = aws_security_group.lore_nlb.id
  description       = "Lore UDP ${each.value} to pods"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "udp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}

resource "aws_vpc_security_group_ingress_rule" "node_lore_replication" {
  security_group_id            = var.node_security_group_id
  description                  = "Lore edge-to-write mTLS QUIC replication"
  referenced_security_group_id = var.node_security_group_id
  ip_protocol                  = "udp"
  from_port                    = 41340
  to_port                      = 41340
}

data "aws_iam_policy_document" "pod_identity_assume_role" {
  statement {
    sid     = "EKSPodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "edge" {
  name                 = "${var.cluster_name}-lore-edge"
  description          = "EKS Pod Identity role for Lore edge replicas"
  assume_role_policy   = data.aws_iam_policy_document.pod_identity_assume_role.json
  permissions_boundary = var.permissions_boundary_arn

  tags = local.common_tags
}

resource "aws_iam_role" "write" {
  name                 = "${var.cluster_name}-lore-write"
  description          = "EKS Pod Identity role for Lore durable write replicas"
  assume_role_policy   = data.aws_iam_policy_document.pod_identity_assume_role.json
  permissions_boundary = var.permissions_boundary_arn

  tags = local.common_tags
}

resource "aws_iam_role" "otel" {
  name                 = "${var.cluster_name}-lore-otel"
  description          = "EKS Pod Identity role for the Lore ADOT gateway"
  assume_role_policy   = data.aws_iam_policy_document.pod_identity_assume_role.json
  permissions_boundary = var.permissions_boundary_arn

  tags = local.common_tags
}

data "aws_iam_policy_document" "edge" {
  statement {
    sid = "MutableMetadata"
    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:TransactGetItems",
      "dynamodb:TransactWriteItems",
      "dynamodb:UpdateItem",
    ]
    resources = [aws_dynamodb_table.mutable_store.arn]
  }

  statement {
    sid = "DistributedLocks"
    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:TransactGetItems",
      "dynamodb:TransactWriteItems",
      "dynamodb:UpdateItem",
    ]
    resources = [
      aws_dynamodb_table.locks.arn,
      "${aws_dynamodb_table.locks.arn}/index/*",
    ]
  }

  statement {
    sid       = "RuntimeCertificates"
    actions   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.runtime.arn]
  }

  statement {
    sid       = "LoreKMS"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = [aws_kms_key.lore.arn]
  }
}

resource "aws_iam_role_policy" "edge" {
  name   = "lore-edge-runtime"
  role   = aws_iam_role.edge.id
  policy = data.aws_iam_policy_document.edge.json
}

data "aws_iam_policy_document" "write" {
  statement {
    sid     = "ListFragmentBucket"
    actions = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
    resources = [
      aws_s3_bucket.fragments.arn,
    ]
  }

  statement {
    sid = "FragmentObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.fragments.arn}/*"]
  }

  statement {
    sid = "LoreTables"
    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:TransactGetItems",
      "dynamodb:TransactWriteItems",
      "dynamodb:UpdateItem",
    ]
    resources = flatten([
      for arn in values(local.table_arns) : [arn, "${arn}/index/*"]
    ])
  }

  statement {
    sid       = "RuntimeCertificates"
    actions   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.runtime.arn]
  }

  statement {
    sid       = "LoreKMS"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = [aws_kms_key.lore.arn]
  }
}

resource "aws_iam_role_policy" "write" {
  name   = "lore-write-runtime"
  role   = aws_iam_role.write.id
  policy = data.aws_iam_policy_document.write.json
}

resource "aws_cloudwatch_log_group" "lore_metrics" {
  name              = "/aws/lore/${var.cluster_name}/metrics"
  retention_in_days = 90

  tags = local.common_tags
}

data "aws_iam_policy_document" "otel" {
  statement {
    sid       = "LoreMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["UnrealOps/Lore"]
    }
  }

  statement {
    sid = "LoreMetricLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lore_metrics.arn}:*"]
  }

  statement {
    sid = "LoreTraces"
    actions = [
      "xray:GetSamplingRules",
      "xray:GetSamplingStatisticSummaries",
      "xray:GetSamplingTargets",
      "xray:PutTelemetryRecords",
      "xray:PutTraceSegments",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "otel" {
  name   = "lore-otel-export"
  role   = aws_iam_role.otel.id
  policy = data.aws_iam_policy_document.otel.json
}

resource "aws_eks_pod_identity_association" "edge" {
  cluster_name    = var.cluster_name
  namespace       = "lore"
  service_account = "lore-edge"
  role_arn        = aws_iam_role.edge.arn

  tags = local.common_tags
}

resource "aws_eks_pod_identity_association" "write" {
  cluster_name    = var.cluster_name
  namespace       = "lore"
  service_account = "lore-write"
  role_arn        = aws_iam_role.write.arn

  tags = local.common_tags
}

resource "aws_eks_pod_identity_association" "otel" {
  cluster_name    = var.cluster_name
  namespace       = "lore"
  service_account = "lore-otel"
  role_arn        = aws_iam_role.otel.arn

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  for_each = local.table_names

  alarm_name          = "${each.value}-throttled-requests"
  alarm_description   = "Lore DynamoDB table ${each.value} is throttling requests"
  namespace           = "AWS/DynamoDB"
  metric_name         = "ThrottledRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    TableName = each.value
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "dynamodb_system_errors" {
  for_each = local.table_names

  alarm_name          = "${each.value}-system-errors"
  alarm_description   = "Lore DynamoDB table ${each.value} returned system errors"
  namespace           = "AWS/DynamoDB"
  metric_name         = "SystemErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    TableName = each.value
  }

  tags = local.common_tags
}
