###############################################################################
# One IAM role per add-on, scoped to one service account. Nothing on the node
# role. Policies are passed as maps keyed by a stable name because for_each keys
# become state addresses and must be known at plan time.
###############################################################################

# --- AWS Load Balancer Controller --------------------------------------------
# Vendored from the controller's own repo: the policy changes between releases
# and a wrong one leaves Ingress pending with no useful error. Broad by nature;
# the controller creates load balancers, target groups, listeners and SGs.
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
# The operator holds no AWS identity; each namespace brings its own service
# account and role. A namespaced SecretStore may only reference a service
# account in its own namespace, enforced by the admission webhook.
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

    # The same key encrypts Terraform state and container images. ViaService
    # limits this identity to Secrets Manager, so it cannot decrypt state.
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
# The controller creates the load balancer, so Terraform never learns its DNS
# name and cannot write the record itself. external-dns reads the Ingress
# instead, keeping the hostname defined in one place.
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
    # These actions have no resource-level permissions. The write above is the
    # constrained one, scoped to the delegated zone.
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
