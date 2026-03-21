# CDN + WAF Module — Provider Requirements
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# NOTE: This module requires two AWS provider configurations:
#   - default: for CloudFront distribution (any region)
#   - aws.us_east_1: for WAFv2 (must be us-east-1 for CloudFront scope)

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}
