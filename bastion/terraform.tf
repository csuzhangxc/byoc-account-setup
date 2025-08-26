terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "YOUR_S3_BUCKET"
    key =  "TF_STATE_FILE_PATH"
    region = "us-west-2"
  }
}

provider "aws" {
  region = var.aws_region
}