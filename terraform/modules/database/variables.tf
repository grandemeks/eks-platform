variable "name" {
  description = "Name prefix for every resource in this module."
  type        = string
}

variable "vpc_id" {
  description = "VPC the database lives in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the DB subnet group. RDS requires at least two AZs even for a single-AZ instance."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups permitted to reach the database, keyed by a stable name. Keys must be known at plan time, so a map is used rather than a list of IDs resolved during apply."
  type        = map(string)
}

variable "kms_key_arn" {
  description = "CMK used for storage encryption, Performance Insights, and the master password secret."
  type        = string
}

variable "engine_major_version" {
  description = "PostgreSQL major version. The minor is resolved at plan time and upgraded automatically in the maintenance window."
  type        = string
  default     = "18"
}

variable "instance_class" {
  description = "RDS instance class. The default is the cheapest burstable class that still supports Performance Insights; a production instance would use a non-burstable class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Upper bound for storage autoscaling. Keep it above allocated_storage so the instance grows instead of hitting storage-full."
  type        = number
  default     = 50
}

variable "multi_az" {
  description = "Run a standby in a second AZ. Off by default because it roughly doubles the instance cost; production sets it to true."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Days of automated backups. Any value above zero also enables point-in-time recovery."
  type        = number
  default     = 1
}

variable "deletion_protection" {
  description = "Blocks deletion through the API. Off for an environment that is torn down daily."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on deletion. True here because the schema is recreated by the application on startup; production sets it to false."
  type        = bool
  default     = true
}

variable "database_name" {
  description = "Initial database created on the instance."
  type        = string
  default     = "demo"
}

variable "master_username" {
  description = "Master user. The password is generated and held by RDS in Secrets Manager, never by Terraform."
  type        = string
  default     = "dbadmin"
}

variable "performance_insights_retention_period" {
  description = "Days of Performance Insights retention. 7 is the free tier."
  type        = number
  default     = 7
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring granularity in seconds. 0 disables it."
  type        = number
  default     = 60
}

variable "log_retention_days" {
  description = "CloudWatch retention for exported database logs."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
