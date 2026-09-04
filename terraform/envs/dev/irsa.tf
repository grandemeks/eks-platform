###############################################################################
# In-cluster AWS identities
#
# Every add-on that touches the AWS API gets its own role, scoped to its own
# service account. No shared identity, and nothing inherited by the node role.
#
# Note the pattern across all three: policies are passed as maps keyed by a
# stable name, never as lists. for_each keys become resource addresses in state
# and must be known at plan time; only the values may be resolved during apply.
###############################################################################

# --- AWS Load Balancer Controller --------------------------------------------
#
# The policy is vendored from the controller's own repository rather than
# hand-written: it is long, it changes between controller releases, and getting
# it wrong produces an Ingress that hangs with no useful error. The file is
# committed so the version in use is visible in Git history and diffable on
# upgrade.
#
# This role is broad, and honestly so. The controller creates load balancers,
# target groups, listeners and security groups; a policy enumerating those with
# wildcards would look scoped without being any narrower.
resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "${local.name}-aws-load-balancer-controller"
  description = "Vendored from kubernetes-sigs/aws-load-balancer-controller v3.5.0"
  policy      = file("${path.module}/policies/aws-load-balancer-controller.json")
}

module "irsa_aws_load_balancer_controller" {
  source = "../../modules/irsa-role"

  name              = "${local.name}-aws-load-balancer-controller"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_host  = module.eks.oidc_issuer_host

  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"

  policy_arns = {
    controller = aws_iam_policy.aws_load_balancer_controller.arn
  }
}

# --- Secrets access for the demo namespace ------------------------------------
#
# The External Secrets operator itself holds no AWS identity. Each namespace
# brings its own service account and its own role, and the operator mints a
# token for it. A namespaced SecretStore may only reference a service account
# in its own namespace — the admission webhook enforces this — which is what
# makes the boundary real rather than conventional.
#
# The contrast with the controller role above is the point: this one is
# genuinely least privilege. Read exactly one secret, decrypt with exactly one
# key, nothing else. If it leaked it could read one database password and could
# not enumerate what else exists in the account.
data "aws_iam_policy_document" "demo_app_secrets" {
  statement {
    sid    = "ReadDatabaseCredentialOnly"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [module.database.master_user_secret_arn]
  }

  statement {
    sid       = "DecryptWithPlatformKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.platform.target_key_arn]

    # The same key encrypts Terraform state and container images. This
    # condition means the identity can use it only through Secrets Manager, so
    # it cannot decrypt state even though it can use the key.
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

module "irsa_demo_app_secrets" {
  source = "../../modules/irsa-role"

  name              = "${local.name}-demo-app-secrets"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_host  = module.eks.oidc_issuer_host

  namespace       = "demo"
  service_account = "demo-app-secrets"

  inline_policies = {
    scoped = data.aws_iam_policy_document.demo_app_secrets.json
  }
}

# --- external-dns -------------------------------------------------------------
#
# The load balancer is created by the controller, so Terraform never learns its
# DNS name and cannot write the Route53 record itself. external-dns closes that
# loop by reading the Ingress and maintaining the record, which keeps the
# hostname defined in exactly one place instead of duplicated between Terraform
# and Kubernetes where the two would drift.
data "aws_route53_zone" "demo" {
  name         = var.dns_zone_name
  private_zone = false
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid       = "ChangeRecordsInDelegatedZoneOnly"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.demo.zone_id}"]
  }

  statement {
    sid    = "DiscoverZonesAndRecords"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResources",
    ]
    # List operations do not support resource-level permissions. They are
    # read-only; the write above is the one that is actually constrained, and
    # it is constrained to the delegated subdomain's zone. This identity cannot
    # touch the apex domain, which is not in this account at all.
    resources = ["*"]
  }
}

module "irsa_external_dns" {
  source = "../../modules/irsa-role"

  name              = "${local.name}-external-dns"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_host  = module.eks.oidc_issuer_host

  namespace       = "kube-system"
  service_account = "external-dns"

  inline_policies = {
    scoped = data.aws_iam_policy_document.external_dns.json
  }
}
