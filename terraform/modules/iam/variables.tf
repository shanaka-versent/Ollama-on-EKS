# IAM Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "create_ebs_csi_role" {
  description = "Create IAM role for EBS CSI Driver (IRSA)"
  type        = bool
  default     = false
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN (required for IRSA roles)"
  type        = string
  default     = ""
}

variable "oidc_provider_url" {
  description = "EKS OIDC provider URL without https:// (required for IRSA roles)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
