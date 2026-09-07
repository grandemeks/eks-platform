terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# IRSA trust policy in one place, so it is written correctly once rather than
# copied per add-on. No key material anywhere: the service account's projected
# token is exchanged for temporary credentials.

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
  description = "Existing policies to attach, keyed by a stable name. A map, because for_each keys must be known at plan time while a policy ARN from the same apply is not."
  type        = map(string)
  default     = {}
}

variable "inline_policies" {
  description = "Inline policy documents, keyed by a stable name. A map for the same reason as policy_arns: the key stays static and only the document is resolved during apply."
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

    # Pins one service account in one namespace. Without it, any pod in the
    # cluster could assume the role.
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
  description = "Role ARN for the eks.amazonaws.com/role-arn annotation on the service account."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}
