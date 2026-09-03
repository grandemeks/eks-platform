output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC, used when writing security group rules."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, sorted for stable ordering."
  value       = [for az in sort(keys(aws_subnet.public)) : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs, sorted for stable ordering."
  value       = [for az in sort(keys(aws_subnet.private)) : aws_subnet.private[az].id]
}

output "nat_public_ips" {
  description = "Public IPs of the NAT gateways. Stable egress addresses, useful when a third party needs an allowlist."
  value       = [for az in sort(keys(aws_eip.nat)) : aws_eip.nat[az].public_ip]
}