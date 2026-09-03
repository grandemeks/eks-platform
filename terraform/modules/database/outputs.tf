output "endpoint" {
  description = "Host:port of the instance."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Hostname only, which is what the application's DB_HOST expects."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "database_name" {
  value = aws_db_instance.this.db_name
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "engine_version" {
  description = "Resolved minor version actually running."
  value       = aws_db_instance.this.engine_version
}

output "master_user_secret_arn" {
  description = <<-EOT
    ARN of the Secrets Manager secret RDS manages for the master user. This is
    what External Secrets reads to build the Kubernetes Secret. The ARN itself
    is not sensitive — reading it requires IAM permission and the CMK.
  EOT
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
