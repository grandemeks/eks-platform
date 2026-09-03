output "state_bucket_name" {
  description = "S3 bucket holding Terraform state."
  value       = aws_s3_bucket.tfstate.id
}

output "kms_key_arn" {
  description = "Shared CMK ARN, reused by later stacks."
  value       = aws_kms_key.platform.arn
}