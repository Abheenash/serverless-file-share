terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Remote state — bootstrap an S3 bucket once, then uncomment. Uses S3-native
  # locking (no DynamoDB lock table needed on recent Terraform).
  # backend "s3" {
  #   bucket       = "sfs-tfstate-<account_id>"
  #   key          = "serverless-file-share/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "serverless-file-share"
      IaC     = "terraform"
    }
  }
}
