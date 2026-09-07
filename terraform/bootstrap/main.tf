# One CMK for everything this platform stores: state, ECR, RDS, etcd secrets.
resource "aws_kms_key" "platform" {
  description             = "${var.project} shared encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

# Stable name to reference; the key UUID changes if the key is ever replaced.
resource "aws_kms_alias" "platform" {
  name          = "alias/${var.project}"
  target_key_id = aws_kms_key.platform.key_id
}

# Terraform state for every stack in this repo. Account ID suffix because S3
# bucket names are globally unique.
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  # Must survive a destroy of everything it describes.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # The recovery path for a corrupted or truncated state write.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.platform.arn
    }
    # One KMS call per bucket key instead of one per object.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}