output "vpc_id" {
  value = module.network.vpc_id
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "nat_public_ips" {
  description = "Stable egress addresses for anything that needs an allowlist."
  value       = module.network.nat_public_ips
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "configure_kubectl" {
  description = "Copy-paste command to point kubectl at this cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "database_endpoint" {
  value = module.database.endpoint
}

output "irsa_aws_load_balancer_controller_role_arn" {
  description = "Annotate the controller's service account with this."
  value       = module.irsa_aws_load_balancer_controller.role_arn
}

output "irsa_demo_app_secrets_role_arn" {
  description = "Annotate the demo namespace secret-reader service account with this."
  value       = module.irsa_demo_app_secrets.role_arn
}

output "database_secret_arn" {
  description = "Full ARN of the RDS-managed credential, referenced by the SecretStore."
  value       = module.database.master_user_secret_arn
}

output "irsa_external_dns_role_arn" {
  value = module.irsa_external_dns.role_arn
}

output "dns_zone_id" {
  value = data.aws_route53_zone.demo.zone_id
}