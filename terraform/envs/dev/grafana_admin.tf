# With grafana.adminPassword unset the chart regenerates it on every render, so
# every Argo sync rewrote the Secret and restarted the pod, while Grafana kept
# the first password in its own database. Result: nobody can log in and the
# sidecars get 401 from the provisioning API. Generate once here instead.

resource "random_password" "grafana_admin" {
  length = 32

  # The value lands in a shell env var and in Grafana API URLs, where a quoting
  # bug is likelier than 32 alphanumeric characters being brute-forced.
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  # Fixed name, not name_prefix: stable across destroy/apply, so the values file
  # can reference it by name instead of an ARN re-synced after every rebuild.
  name        = "${local.name}-grafana-admin"
  description = "Grafana admin credential for ${local.name}, read by External Secrets."

  kms_key_id = data.aws_kms_alias.platform.target_key_arn

  # 0, not the 30-day default: recreating a secret with the same name fails
  # while the old one is still in its recovery window.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id

  # Key names match what the Grafana chart expects, so the ExternalSecret maps
  # one property to one Secret key with no renaming.
  secret_string = jsonencode({
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin.result
  })
}

# --- IRSA ---------------------------------------------------------------------
# Separate role rather than widening the demo-app one, so a compromised demo
# namespace cannot also read Grafana's password.

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

    # Key usable only through Secrets Manager, so this identity cannot decrypt
    # Terraform state with it.
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
