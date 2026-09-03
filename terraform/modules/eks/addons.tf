# Resolved at plan time against the cluster's Kubernetes version rather than
# pinned to literal strings that go stale within weeks. The trade-off is that a
# plan run months apart can select a newer add-on version; pinning belongs in a
# repository with a regular upgrade cadence.
data "aws_eks_addon_version" "this" {
  for_each = toset(["vpc-cni", "kube-proxy", "coredns", "aws-ebs-csi-driver"])

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

# Networking add-ons come first: nodes cannot become Ready without them.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = data.aws_eks_addon_version.this["vpc-cni"].version

  service_account_role_arn = aws_iam_role.vpc_cni.arn

  # Prefix delegation raises the pod limit per node from 35 to 110 on this
  # instance type. Without it, the ENI and secondary-IP model caps pods well
  # below what the available memory could actually run.
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  addon_version = data.aws_eks_addon_version.this["kube-proxy"].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

# These two schedule real pods, so they wait for nodes to exist.
resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  addon_version = data.aws_eks_addon_version.this["coredns"].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]

  tags = var.tags
}

# Required for PersistentVolumeClaims. Prometheus, Grafana and Loki all need
# storage that survives a pod restart.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version

  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]

  tags = var.tags
}