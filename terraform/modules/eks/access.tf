resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  # Iterates over the input variable, not over the access entry resource.
  #
  # for_each keys become resource addresses in state and must be known at plan
  # time. Iterating over aws_eks_access_entry.admin means the keys come from a
  # resource that does not exist yet on a first apply — Terraform knows how
  # many there will be but not what they are called. The variable holds the
  # same values and is known from the configuration.
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  # The reference above is to the cluster, not to the entry, so the ordering
  # has to be stated explicitly: an access policy cannot be associated with a
  # principal that has no access entry yet.
  depends_on = [aws_eks_access_entry.admin]
}