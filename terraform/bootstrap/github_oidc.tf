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

# --- Application image build and push ------------------------------------------
#
# A separate identity from the Terraform role, and genuinely least privilege:
# push to exactly one ECR repository, use one KMS key, nothing else. A job that
# builds a container image has no reason to be able to delete a database, and
# keeping the two apart means a compromised build cannot become a compromised
# account.
data "aws_iam_policy_document" "github_ecr_assume" {
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

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_sub_prefix}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "github_ecr" {
  statement {
    sid       = "AuthToRegistry"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level permissions
  }

  statement {
    sid    = "PushToDemoAppRepositoryOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid    = "UseKeyForImageEncryption"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.platform.arn]
  }
}

resource "aws_iam_role" "github_ecr" {
  name                 = "${var.project}-github-ecr"
  description          = "Assumed by GitHub Actions to build and push the demo application image"
  assume_role_policy   = data.aws_iam_policy_document.github_ecr_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "github_ecr" {
  name   = "ecr-push"
  role   = aws_iam_role.github_ecr.id
  policy = data.aws_iam_policy_document.github_ecr.json
}