terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# IRSA in one reusable place.
#
# A Kubernetes service account presents a projected, signed token; AWS accepts
# it because the cluster's OIDC issuer is a registered identity provider; the
# pod receives temporary credentials. No key material exists anywhere — same
# federation model as the GitHub Actions roles in the bootstrap layer, with the
# cluster as issuer instead of GitHub.
#
# Every add-on that needs AWS access instantiates this module, so the trust
# policy is written correctly once instead of copied four times.

variable "name" {
  description = "Role name."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider."
  type        = string
}

variable "oidc_issuer_host" {
  description = "Issuer hostname without the https:// scheme, used to build the condition keys."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the service account allowed to assume this role."
  type        = string
}

variable "service_account" {
  description = "Name of that service account."
  type        = string
}

variable "policy_arns" {
  description = <<-EOT
    Existing policies to attach, keyed by a stable name.

    A map rather than a list because for_each keys must be known at plan time,
    and a policy ARN produced by another resource in the same apply is not.
    With a map the key is written in configuration and only the value is
    resolved later, which is what lets the plan proceed.
  EOT
  type        = map(string)
  default     = {}
}

variable "inline_policies" {
  description = <<-EOT
    Inline policy documents, keyed by a stable name.

    Same reason as policy_arns: a policy built from ARNs that other modules
    produce is not known at plan time, and count cannot depend on an unknown
    value. With a map, the key is static and only the document is resolved
    during apply.
  EOT
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Pins one service account in one namespace. Without this condition any pod
    # in the cluster could assume the role — the in-cluster equivalent of the
    # missing-sub mistake on the GitHub Actions side.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }

    # Rejects a token minted for a different audience and replayed here.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  description        = "IRSA role for ${var.namespace}/${var.service_account}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = var.policy_arns

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  for_each = var.inline_policies

  name   = each.key
  role   = aws_iam_role.this.id
  policy = each.value
}

output "role_arn" {
  description = "Goes into the eks.amazonaws.com/role-arn annotation on the service account."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}
