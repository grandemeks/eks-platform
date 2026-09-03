# Registers GitHub Actions as a trusted identity provider in this account
# One per account; every CI role trusts this same provider.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  github_sub_prefix = "repo:${var.github_owner}/${var.github_repo}"
}

# Datasource that generates JSON
data "aws_iam_policy_document" "github_terraform_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only these two entry points. A feature branch or a tag cannot assume
    # this role, even from within this same repository.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.github_sub_prefix}:ref:refs/heads/main",
        "${local.github_sub_prefix}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "github_terraform" {
  name                 = "${var.project}-github-terraform"
  description          = "Assumed by GitHub Actions to plan and apply infrastructure"
  assume_role_policy   = data.aws_iam_policy_document.github_terraform_assume.json
  max_session_duration = 3600
}

# TRADE-OFF: Terraform here creates VPCs, EKS clusters, IAM roles and RDS
# instances, so the permission set is genuinely broad.
resource "aws_iam_role_policy_attachment" "github_terraform_admin" {
  role       = aws_iam_role.github_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}