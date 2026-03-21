# cert-manager Module — Provider Requirements
# @author Shanaka Jayasundera - shanakaj@gmail.com

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.10"
    }
  }
}
