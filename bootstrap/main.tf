# One-time setup: the S3 bucket that holds Terraform state for envs/dev.
# This module keeps its own state locally; it only creates the bucket.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = { Project = "aws-terraform-hands-on", ManagedBy = "terraform" } }
}

variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state"
  type        = string
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:Single-owner state bucket; access logging needs a second bucket
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles storage; versioning covers recovery here
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is enabled; KMS adds a key to manage for a demo
  #checkov:skip=CKV2_AWS_62:No consumers of bucket events
  bucket = var.bucket_name

  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Refuse any request that is not over TLS.
resource "aws_s3_bucket_policy" "tls_only" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Old state versions are kept for recovery, but not forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

output "bucket" { value = aws_s3_bucket.state.id }
