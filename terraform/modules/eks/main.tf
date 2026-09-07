# Pre-created so retention is ours. EKS would otherwise create it with
# never-expire retention.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids = var.private_subnet_ids

    # Private for nodes and in-cluster workloads, public for kubectl and CI.
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    # API replaces the aws-auth ConfigMap: access entries are real AWS
    # resources Terraform can manage, and are far harder to lock yourself out of.
    authentication_mode = "API"

    bootstrap_cluster_creator_admin_permissions = false
  }

  # Envelope encryption in etcd. Without it, Secrets are only base64 at rest.
  encryption_config {
    provider {
      key_arn = var.kms_key_arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  # Neither ordering is inferable from a reference.
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]

  tags = var.tags
}

# --- IRSA ---------------------------------------------------------------------
# Registering the cluster's OIDC issuer lets a service account assume an IAM
# role directly, so a pod gets scoped credentials with no stored key.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = var.tags
}