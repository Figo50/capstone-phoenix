# Fill in bucket + dynamodb_table with the outputs from
# infra/terraform-bootstrap/ after you run it once. Then:
#   terraform init -migrate-state
# to move your existing local state into S3 without losing it.

terraform {
  backend "s3" {
    bucket         = "capstone-phoenix-tfstate-6d3af60b"
    key            = "capstone-phoenix/terraform.tfstate"
    region         = "eu-north-1"
    dynamodb_table = "capstone-phoenix-tf-lock"
    encrypt        = true
  }
}
