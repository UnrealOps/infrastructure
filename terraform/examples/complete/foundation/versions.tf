terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.58.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      Environment = var.name
      ManagedBy   = "Terraform"
      Project     = "UnrealOps"
    })
  }
}

data "aws_partition" "current" {}
