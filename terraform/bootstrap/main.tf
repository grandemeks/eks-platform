# KMS key used to encrypt everything this platform stores, same key for RDS and ECR
resource "aws_kms_key" "platform" {
  description             = "${var.project} shared encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

# Alias for key's UUID for stable name
resource "aws_kms_alias" "platform" {
  name          = "alias/${var.project}"
  target_key_id = aws_kms_key.platform.key_id
}

# S3 bucket holding Terraform state for every resource in this repo
# Adding account_id as a sufix for the name as S3 name must be unique
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  # S3 never gets deleted on terraform destroy
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # Each state file change will save previous version  
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
    # Saving costs, prevents S3 to call KMS for each single object
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