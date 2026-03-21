# AWS Managed Grafana Module - Provider Requirements
# @author Shanaka Jayasundera - shanakaj@gmail.com

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
