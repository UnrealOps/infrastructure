data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

module "account_bootstrap" {
  source = "../../../modules/account-bootstrap"

  role_name = var.name
  role_path = "/unrealops/"
  trusted_principal_arns = [
    data.aws_iam_session_context.current.issuer_arn,
  ]
  cluster_names = [var.cluster_name]

  tags = {
    Test = var.name
  }
}
