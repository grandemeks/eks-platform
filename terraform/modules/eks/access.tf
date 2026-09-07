resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  # for_each keys must be known at plan time, so this iterates the variable and
  # not aws_eks_access_entry.admin, which does not exist on a first apply.
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  # Nothing above references the entry, so the ordering has to be explicit: a
  # policy cannot attach to a principal with no access entry.
  depends_on = [aws_eks_access_entry.admin]
}