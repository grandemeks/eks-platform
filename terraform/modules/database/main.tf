terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Newest minor inside the pinned major, resolved at plan time.
data "aws_rds_engine_version" "postgres" {
  engine  = "postgres"
  version = var.engine_major_version
  latest  = true
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = var.name })
}

# No inline rules: inline blocks and standalone rule resources fight, and
# Terraform strips anything not declared inline on every apply.
resource "aws_security_group" "this" {
  name_prefix = "${var.name}-rds-"
  description = "Postgres access for ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-rds" })

  # The instance holds a reference, so a replacement must create the new group
  # before the old one is destroyed.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = var.allowed_security_group_ids

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value

  from_port   = 5432
  to_port     = 5432
  ip_protocol = "tcp"
  description = "PostgreSQL from ${each.key}"
}

# No egress rule: RDS initiates nothing outbound, and AWS attaches no default
# allow-all when none is declared.

# -----------------------------------------------------------------------------
# Parameters
# -----------------------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-"
  family      = "postgres${var.engine_major_version}"
  description = "Parameters for ${var.name}"

  # force_ssl server-side. sslmode=require on the client alone verifies nothing.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # 1s threshold: attributes a latency spike without logging every statement.
  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  # Makes connection-pool churn visible in logs, not just in metrics.
  parameter {
    name         = "log_connections"
    value        = "all"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Instance
# -----------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier = var.name

  engine         = "postgres"
  engine_version = data.aws_rds_engine_version.postgres.version
  instance_class = var.instance_class

  # gp3: baseline throughput is independent of volume size, so 20 GB is not
  # IOPS-starved the way gp2 would be.
  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  db_name  = var.database_name
  username = var.master_username

  # RDS generates and rotates the password into Secrets Manager, so it never
  # reaches state, a plan output or a CI log. random_password would.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  publicly_accessible = false

  multi_az = var.multi_az

  backup_retention_period = var.backup_retention_period
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot   = true

  # Minor upgrades ride the maintenance window; majors are a tested migration.
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  # Query-level visibility: which statements are waiting, and on what.
  performance_insights_enabled          = true
  performance_insights_retention_period = var.performance_insights_retention_period
  performance_insights_kms_key_id       = var.kms_key_arn

  # Per-process CPU and memory and disk queue depth, none of which standard
  # CloudWatch instance metrics carry.
  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  deletion_protection = var.deletion_protection
  skip_final_snapshot = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : (
    "${var.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  )

  # Torn down daily. Production would queue changes for the maintenance window.
  apply_immediately = true

  # RDS creates these groups itself with never-expire retention the moment it
  # starts exporting, colliding with the resource below. Creating them first is
  # what makes the retention setting stick.
  depends_on = [aws_cloudwatch_log_group.postgres]

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    ignore_changes = [
      # timestamp() is recomputed every plan: permanent diff otherwise.
      final_snapshot_identifier,
      # RDS applies minor upgrades, not Terraform.
      engine_version,
    ]
  }
}

# RDS would create these with no expiry, so without this they bill forever.
resource "aws_cloudwatch_log_group" "postgres" {
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${var.name}/${each.value}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
