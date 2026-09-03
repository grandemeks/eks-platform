###############################################################################
# In-cluster AWS identities
#
# Each add-on that touches the AWS API gets its own role, scoped to its own
# service account. No shared identity, and nothing inherited by the node role.
###############################################################################

# --- AWS Load Balancer Controller --------------------------------------------
#
# The policy is vendored from the controller's own repository rather than
# hand-written: it is long, it changes between controller releases, and getting
# it wrong produces an Ingress that hangs with no useful error. The file is
# committed so the version in use is visible in Git history and diffable on
# upgrade.
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

# --- Per-namespace secret access ---------------------------------------------
#
# The External Secrets operator itself holds no AWS identity. Instead each
# namespace brings its own service account and its own role, and the operator
# mints a token for it. A namespaced SecretStore may only reference a service
# account in its own namespace, which is what enforces the boundary: a
# workload in another namespace cannot borrow this identity even by name.
#
# The alternative, a ClusterSecretStore bound to one operator-wide role, is
# simpler to write and makes a single AWS identity reachable from every
# namespace in the cluster.
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
    # condition means the identity can use it only through Secrets Manager.
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

  inline_policy_json = data.aws_iam_policy_document.demo_app_secrets.json
}