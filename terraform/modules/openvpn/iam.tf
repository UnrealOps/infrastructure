data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "Ec2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-openvpn"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(local.tags, {
    Name = "${var.name}-openvpn"
  })
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "ReadRuntimeSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.runtime_secret_arn]
  }

  dynamic "statement" {
    for_each = var.runtime_secret_kms_key_arn == null ? [] : [var.runtime_secret_kms_key_arn]

    content {
      sid       = "DecryptRuntimeSecret"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"]
      }
    }
  }

  statement {
    sid    = "ManageStableAddress"
    effect = "Allow"
    actions = [
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
    ]
    resources = [
      aws_eip.this.arn,
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
    ]
  }

  statement {
    sid       = "DisableSourceDestinationCheck"
    effect    = "Allow"
    actions   = ["ec2:ModifyInstanceAttribute"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*"]
  }

  statement {
    sid    = "DescribeBootstrapResources"
    effect = "Allow"
    actions = [
      "ec2:DescribeAddresses",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageOwnLifecycle"
    effect = "Allow"
    actions = [
      "autoscaling:CompleteLifecycleAction",
      "autoscaling:RecordLifecycleActionHeartbeat",
      "autoscaling:SetInstanceHealth",
    ]
    resources = [local.asg_arn]
  }

  statement {
    sid    = "WriteOpenVpnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:log-stream:*"]
  }

  statement {
    sid       = "DescribeOpenVpnLogStreams"
    effect    = "Allow"
    actions   = ["logs:DescribeLogStreams"]
    resources = [aws_cloudwatch_log_group.this.arn]
  }

  statement {
    sid       = "DescribeLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "WriteOpenVpnMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["CWAgent"]
    }
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${var.name}-openvpn-runtime"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-openvpn"
  role = aws_iam_role.this.name

  tags = local.tags
}
