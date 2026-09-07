###############################################################################
# GitHub Actions -> AWS via OIDC. No access keys stored in GitHub; the trust
# policies below are where least privilege is enforced.
###############################################################################

# One provider per account. AWS validates the chain for this well-known issuer,
# so no thumbprint pinning is required.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

variable "github_owner_id" {
  description = <<-EOT
    Numeric GitHub account ID of the repository owner. The OIDC sub claim on
    this account carries numeric IDs rather than names, and an ID is never
    reissued. Find it with: gh api /users/<owner> --jq .id
  EOT
  type        = string
  default     = "219707368"
}

variable "github_repo_id" {
  description = "Numeric ID of the repository. Find it with: gh api /repos/<owner>/<repo> --jq .id"
  type        = string
  default     = "1355825582"
}

locals {
  github_sub_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"
}

# -----------------------------------------------------------------------------
# Role 1: Terraform plan and apply
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "github_terraform_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # Rejects a token minted for a different audience and replayed here.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # GitHub rewrites sub when a job declares an `environment:`: a job on main
    # inside environment dev presents environment:dev, not ref:refs/heads/main.
    # StringEquals, not StringLike: repo:owner/repo:* would let any branch
    # assume a role holding AdministratorAccess.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.github_sub_prefix}:ref:refs/heads/main",
        "${local.github_sub_prefix}:pull_request",
        "${local.github_sub_prefix}:environment:dev",
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

# This stack creates VPCs, EKS clusters, IAM roles and RDS instances, so an
# enumerated ec2:*/eks:*/iam:*/rds:* policy would be no narrower, only longer.
# Scoping is on the trust side above. Production wants a permissions boundary.
resource "aws_iam_role_policy_attachment" "github_terraform_admin" {
  role       = aws_iam_role.github_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# -----------------------------------------------------------------------------
# Role 2: application image build and push. One ECR repository, one KMS key,
# nothing else. Trust is narrower too: main only, no environment, no
# pull_request.
# -----------------------------------------------------------------------------
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
