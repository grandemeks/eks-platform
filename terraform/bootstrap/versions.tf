terraform {
  required_version = ">= 1.11" # use_lockfile below needs 1.11+

  backend "s3" {
    bucket       = "eks-platform-tfstate-385291933614"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags { # cost allocation
    tags = {
      Project   = var.project
      Layer     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {} # account ID for the state bucket name