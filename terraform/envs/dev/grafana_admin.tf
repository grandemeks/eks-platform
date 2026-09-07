# Grafana's admin credential, held in Secrets Manager and delivered into the
# cluster by External Secrets — the same path the database credential takes.
#
# The problem this replaces: with grafana.adminPassword unset, the chart
# generates the password with randAlphaNum, which produces a different value on
# every render. Argo CD re-renders on every sync, so the Secret was rewritten
# each time, and because the pod template carries a checksum over that Secret
# the Grafana pod was restarted each time too. Grafana keeps its admin password
# in its own database and does not re-apply the environment value to an admin
# user that already exists, so the value in the Secret matched only until the
# first sync after installation — after that nobody could log in, and Grafana's
# own sidecars were answered 401 when they called the provisioning reload API.
#
# A password generated here is generated once and stored. Terraform holds it in
# state, which is encrypted with the platform CMK in a bucket no human reads
# directly; Secrets Manager holds it for the cluster to fetch. Neither is Git.

resource "random_password" "grafana_admin" {
  length = 32

  # Alphanumeric only. The value ends up in a shell environment variable inside
  # the container and in a URL when someone uses the Grafana API, and quoting
  # bugs in either place are far more likely than 32 alphanumeric characters
  # being brute-forced.
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  # No name_prefix. Unlike the RDS-managed secret, this one is created by us and
  # its name is therefore stable across a destroy/apply — which is what lets the
  # values file reference it by name instead of by an ARN that has to be synced
  # in after every rebuild.
  name        = "${local.name}-grafana-admin"
  description = "Grafana admin credential for ${local.name}, read by External Secrets."

  kms_key_id = data.aws_kms_alias.platform.target_key_arn

  # Zero, so a destroy/apply cycle can reuse the name immediately. The default
  # is a 30-day recovery window, during which creating a secret with the same
  # name fails — which would break every rebuild of this environment.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id

  # A JSON document with the same key names the Grafana chart expects, so the
  # ExternalSecret maps one property to one Secret key and no renaming happens
  # in between.
  secret_string = jsonencode({
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin.result
  })
}

# --- IRSA ---------------------------------------------------------------------
#
# A second, separate identity rather than widening the demo-app one. The
# blast radius of the demo-app role is one database credential; adding Grafana's
# secret to it would mean a compromised demo-app namespace could read Grafana's
# password too, for no benefit beyond one fewer role.

data "aws_iam_policy_document" "grafana_secrets" {
  statement {
    sid    = "ReadGrafanaAdminCredentialOnly"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.grafana_admin.arn]
  }

  statement {
    sid       = "DecryptWithPlatformKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.platform.target_key_arn]

    # Same condition as the demo-app role: the key is usable only through
    # Secrets Manager, so this identity cannot decrypt Terraform state with it.
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

module "irsa_grafana_secrets" {
  source = "../../modules/irsa-role"

  name              = "${local.name}-grafana-secrets"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_host  = module.eks.oidc_issuer_host

  namespace       = "monitoring"
  service_account = "grafana-secrets"

  inline_policies = {
    scoped = data.aws_iam_policy_document.grafana_secrets.json
  }
}
