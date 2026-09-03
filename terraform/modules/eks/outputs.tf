output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Security group EKS manages for control plane to node traffic. Referenced by the RDS rule so only the cluster can reach the database."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "Used by every IRSA role created outside this module."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_issuer_host" {
  description = "Issuer hostname without scheme, for building IRSA trust conditions."
  value       = local.oidc_issuer_host
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}