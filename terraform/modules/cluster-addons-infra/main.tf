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

resource "aws_iam_policy" "load_balancer_controller" {
  name        = "${var.cluster_name}-aws-load-balancer-controller"
  description = "Official IAM policy for AWS Load Balancer Controller v3.4.3"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-v3.4.3.json")

  tags = var.tags
}

resource "aws_iam_role" "load_balancer_controller" {
  name                 = "${var.cluster_name}-aws-load-balancer-controller"
  description          = "EKS Pod Identity role for the AWS Load Balancer Controller"
  assume_role_policy   = data.aws_iam_policy_document.pod_identity_assume_role.json
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.load_balancer_controller.arn

  tags = var.tags
}
