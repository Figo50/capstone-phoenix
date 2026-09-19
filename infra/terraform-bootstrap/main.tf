# infra/terraform-bootstrap/
#
# ONE-TIME SETUP. Run this ONCE, manually, before touching infra/terraform/.
# It creates the S3 bucket + DynamoDB table that infra/terraform/ will use
# as its remote state backend. This can't live in infra/terraform/ itself,
# because Terraform can't create a backend and use it in the same apply
# (chicken-and-egg problem).
#
# This bootstrap keeps its OWN local state file (terraform-bootstrap/terraform.tfstate).
# That file is small, changes rarely, and is fine to keep local + in .gitignore.
# You will not run `terraform apply` in this directory again after the first time,
# unless you deliberately change the bucket/table config.

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-north-1"
}

# Bucket names must be globally unique across ALL of AWS, not just your account.
# random_id appends a few random hex chars so this doesn't collide with someone else's.
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "tf_state" {
  bucket = "capstone-phoenix-tfstate-${random_id.suffix.hex}"

  # Prevents `terraform destroy` from ever silently deleting your state bucket.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "capstone-phoenix-tfstate" }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled" # lets you recover a previous state file if something corrupts it
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "capstone-phoenix-tf-lock"
  billing_mode = "PAY_PER_REQUEST" # no fixed cost, you pay only per request - fine for solo use
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = { Name = "capstone-phoenix-tf-lock" }
}

output "state_bucket_name" {
  value       = aws_s3_bucket.tf_state.bucket
  description = "Paste this into infra/terraform/backend.tf"
}

output "lock_table_name" {
  value       = aws_dynamodb_table.tf_lock.name
  description = "Paste this into infra/terraform/backend.tf"
}
