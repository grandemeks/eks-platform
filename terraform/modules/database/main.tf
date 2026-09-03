terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Resolves the newest minor release within the pinned major, at plan time.
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

# No inline ingress or egress here. Inline rules and separate rule resources
# fight each other: Terraform removes anything not declared inline on every
# apply. Rules are their own resources below.
resource "aws_security_group" "this" {
  name_prefix = "${var.name}-rds-"
  description = "Postgres access for ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-rds" })

  # The database is referenced by other resources, so replacement has to create
  # the new group before destroying the old one.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value

  from_port   = 5432
  to_port     = 5432
  ip_protocol = "tcp"
  description = "PostgreSQL from the EKS cluster"
}

# Deliberately no egress rule. A managed RDS instance initiates no outbound
# connections, and AWS does not attach a default allow-all rule when none is
# declared. Leaving it out is the tighter configuration, not an omission.

# -----------------------------------------------------------------------------
# Parameters
# -----------------------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-"
  family      = "postgres${var.engine_major_version}"
  description = "Parameters for ${var.name}"

  # Rejects any connection that is not TLS. Without this, sslmode=require on the
  # client is a client-side promise the server never verifies — a misconfigured
  # application could send credentials in the clear and nothing would complain.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Logs every statement slower than a second. The first thing you want when
  # latency climbs and the application metrics point at the database.
  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  # Records connections and disconnections, which makes connection-pool
  # misbehaviour visible in the logs rather than only in metrics.
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

  # gp3 rather than gp2: baseline throughput is independent of volume size, so
  # a 20 GB volume is not starved of IOPS the way gp2 would be.
  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  db_name  = var.database_name
  username = var.master_username

  # The password is generated and rotated by RDS and stored in Secrets Manager.
  # Terraform never sees it, so it cannot appear in state, in a plan output, or
  # in a CI log. The alternative — random_password plus a variable — puts the
  # credential in plaintext in the state file, which is why it is not used here.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  # No public endpoint. The only route to this database is from inside the VPC.
  publicly_accessible = false

  multi_az = var.multi_az

  backup_retention_period = var.backup_retention_period
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot   = true

  # Minor versions carry security fixes and are applied in the maintenance
  # window. Major versions are a deliberate, tested migration, never automatic.
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  # Query-level visibility: which statements are waiting, and on what.
  performance_insights_enabled          = true
  performance_insights_retention_period = var.performance_insights_retention_period
  performance_insights_kms_key_id       = var.kms_key_arn

  # OS-level metrics at a granularity CloudWatch's standard instance metrics
  # cannot reach — per-process CPU and memory, disk queue depth.
  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  deletion_protection = var.deletion_protection
  skip_final_snapshot = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : (
    "${var.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  )

  # Acceptable in an environment that is torn down daily; production would
  # queue changes for the maintenance window instead.
  apply_immediately = true

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    ignore_changes = [
      # Recomputed on every plan and would otherwise show a permanent diff.
      final_snapshot_identifier,
      # Minor upgrades are applied by RDS, not by Terraform.
      engine_version,
    ]
  }
}

# Retention on the exported log groups. RDS creates these itself with no
# expiry, so without this they grow and bill forever.
resource "aws_cloudwatch_log_group" "postgres" {
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${var.name}/${each.value}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
