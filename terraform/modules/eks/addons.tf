# Resolved against the cluster version rather than pinned strings that go stale.
# Cost: two plans months apart can select different add-on versions.
data "aws_eks_addon_version" "this" {
  for_each = toset(["vpc-cni", "kube-proxy", "coredns", "aws-ebs-csi-driver"])

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

# Networking first: nodes cannot become Ready without these two.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = data.aws_eks_addon_version.this["vpc-cni"].version

  service_account_role_arn = aws_iam_role.vpc_cni.arn

  # Prefix delegation raises pods/node from 35 to 110 on t3.large.
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

# These two schedule real pods, so they wait for nodes.
resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  addon_version = data.aws_eks_addon_version.this["coredns"].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]

  tags = var.tags
}

# Required for PVCs: Prometheus, Grafana and Loki all want storage that
# survives a pod restart.
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