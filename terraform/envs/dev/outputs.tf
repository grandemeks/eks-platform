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