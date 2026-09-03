# Pre-created so retention and encryption are under our control. EKS would
# otherwise create this group itself, with retention set to never expire.
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

    # Both endpoints are on: nodes and in-cluster workloads reach the API
    # over the private path, while kubectl and CI use the public one.
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    # "API" replaces the old aws-auth ConfigMap. Access is now granted with
    # real AWS resources that Terraform can manage, rather than by editing a
    # ConfigMap that lived only inside the cluster and was easy to lock
    # yourself out of.
    authentication_mode = "API"

    bootstrap_cluster_creator_admin_permissions = false
  }

  # Envelope encryption for Kubernetes secrets in etcd. Without it, secrets
  # are only base64-encoded at rest.
  encryption_config {
    provider {
      key_arn = var.kms_key_arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  # The role must carry its policy, and the log group must exist, before the
  # cluster is created. Terraform cannot infer either ordering on its own.
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]

  tags = var.tags
}

# --- IRSA ---------------------------------------------------------------------
# Each cluster publishes an OIDC issuer. Registering it as an identity provider
# lets a Kubernetes service account assume an IAM role directly, so a pod gets
# scoped AWS credentials without a single stored key. Same pattern as the
# GitHub Actions federation in the bootstrap layer.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = var.tags
}