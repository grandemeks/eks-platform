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
  description = <<-EOT
    Security groups permitted to reach the database on the Postgres port.
    This is the EKS cluster security group: with the AWS VPC CNI, pods share
    the node's ENI and therefore the node's security groups, so allowing the
    cluster security group is what actually lets a pod connect.

    Referencing a security group rather than a CIDR block means the rule stays
    correct when subnets change, and it cannot accidentally widen to the whole
    VPC.
  EOT
  type        = list(string)
}

variable "kms_key_arn" {
  description = "CMK used for storage encryption, Performance Insights, and the master password secret."
  type        = string
}

variable "engine_major_version" {
  description = <<-EOT
    PostgreSQL major version. Only the major is pinned; the exact minor is
    resolved at plan time and minor upgrades are applied automatically during
    the maintenance window. Pinning the minor would mean a code change for
    every security patch.
  EOT
  type        = string
  default     = "18"
}

variable "instance_class" {
  description = <<-EOT
    db.t4g.micro: Graviton, burstable, and the cheapest class that supports
    Performance Insights. Sufficient for a demo workload; a production
    equivalent would be a non-burstable class so CPU credits cannot run out
    silently under sustained load.
  EOT
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = <<-EOT
    Upper bound for storage autoscaling. Set above allocated_storage so the
    instance grows instead of hitting storage-full, which takes the database
    offline and cannot be fixed quickly.
  EOT
  type        = number
  default     = 50
}

variable "multi_az" {
  description = <<-EOT
    Single-AZ by default: Multi-AZ roughly doubles the instance cost for
    standby capacity that a demo never exercises. This is the single largest
    availability compromise in the environment and is deliberate — production
    sets this to true, which is the whole reason it is a variable.
  EOT
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
  description = <<-EOT
    True for this environment: it is destroyed and recreated constantly, the
    schema is recreated by the application on startup, and a final snapshot on
    every teardown would accumulate storage charges for data with no value.
    Production is the opposite.
  EOT
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
