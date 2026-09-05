###############################################################################
# GitHub Actions -> AWS via OIDC
#
# No AWS access keys are ever stored in GitHub. Workflows exchange a
# short-lived GitHub-issued OIDC token for temporary STS credentials, and the
# trust policy is what enforces least privilege on the identity side.
###############################################################################

# One provider per account; every CI role trusts this same one. AWS validates
# the certificate chain for this well-known issuer, so no thumbprint pinning is
# required.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

variable "github_owner_id" {
  description = <<-EOT
    Numeric GitHub account ID of the repository owner.

    This account issues OIDC tokens whose sub claim carries numeric IDs
    alongside the names:

      repo:owner@<owner_id>/repo@<repository_id>:environment:dev

    rather than the form every published example shows:

      repo:owner/repo:environment:dev

    Binding to the ID is the stronger of the two. A repository can be renamed,
    or deleted and recreated under the same name by someone else; a numeric ID
    is never reissued. The cost is that the mismatch against the documented
    form produces an authentication failure STS reports without naming the
    claim that failed — deliberately, so the error does not leak the policy.
    The only reliable diagnosis is to print the token from a workflow and
    compare its sub claim against the live trust policy.

    Find it with:  gh api /users/<owner> --jq .id
  EOT
  type        = string
  default     = "219707368"
}

variable "github_repo_id" {
  description = <<-EOT
    Numeric ID of the repository.

    Find it with:  gh api /repos/<owner>/<repo> --jq .id
  EOT
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

    # Three entry points, and no more.
    #
    # The third exists because GitHub rewrites the sub claim when a job
    # declares an `environment:`. A job running on main inside an environment
    # does NOT present ref:refs/heads/main — it presents environment:dev
    # instead. Adding the approval gate is what broke authentication the first
    # time this ran.
    #
    # StringEquals rather than StringLike is the point of the whole block. A
    # wildcard such as repo:owner/repo:* would let any branch in the repository
    # assume a role with AdministratorAccess.
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

# TRADE-OFF, and stated openly rather than disguised.
#
# Terraform here creates VPCs, EKS clusters, IAM roles and RDS instances, so
# the permission set is genuinely broad. A hand-written policy enumerating
# ec2:*, eks:*, iam:* and rds:* would be no narrower — only longer, and it
# would look scoped without being so.
#
# Least privilege is enforced on the trust side instead: three exact subjects,
# one of which requires a human approval. The production answer is a
# permissions boundary plus a policy generated from CloudTrail via IAM Access
# Analyzer after a series of real applies.
resource "aws_iam_role_policy_attachment" "github_terraform_admin" {
  role       = aws_iam_role.github_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# -----------------------------------------------------------------------------
# Role 2: application image build and push
#
# A separate identity, and genuinely least privilege: push to exactly one ECR
# repository, use one KMS key, nothing else. A job that builds a container
# image has no reason to be able to delete a database, and keeping the two
# apart means a compromised build cannot become a compromised account.
#
# Note the narrower trust condition too: only main, with no environment and no
# pull request. Nothing else needs to publish an image.
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
