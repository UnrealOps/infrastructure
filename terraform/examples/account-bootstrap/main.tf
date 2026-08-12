data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  effective_trusted_principal_arns = length(var.trusted_principal_arns) > 0 ? var.trusted_principal_arns : toset([
    data.aws_iam_session_context.current.issuer_arn,
  ])
}

module "account_bootstrap" {
  source = "../../modules/account-bootstrap"

  role_name                = var.role_name
  role_path                = var.role_path
  trusted_principal_arns   = local.effective_trusted_principal_arns
  cluster_names            = var.cluster_names
  max_session_duration     = var.max_session_duration
  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = var.tags
}
