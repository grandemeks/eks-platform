output "state_bucket_name" {
  description = "S3 bucket holding Terraform state."
  value       = aws_s3_bucket.tfstate.id
}

output "kms_key_arn" {
  description = "Shared CMK ARN, reused by later stacks."
  value       = aws_kms_key.platform.arn
}

output "dns_zone_id" {
  description = "Hosted zone ID, consumed later by external-dns and ACM validation."
  value       = aws_route53_zone.demo.zone_id
}

output "dns_delegation_records" {
  description = "NS records to create at the register of the parent domain."
  value       = aws_route53_zone.demo.name_servers
}

output "github_terraform_role_arn" {
  description = "Set as the AWS_TERRAFORM_ROLE repo variable in GitHub."
  value       = aws_iam_role.github_terraform.arn
}

output "ecr_repository_url" {
  description = "Registry URL for the demo application image."
  value       = aws_ecr_repository.app.repository_url
}

output "acm_certificate_arn" {
  description = "Issued certificate, referenced by the Ingress annotation."
  value       = aws_acm_certificate_validation.app.certificate_arn
}

output "app_hostname" {
  value = var.app_hostname
}