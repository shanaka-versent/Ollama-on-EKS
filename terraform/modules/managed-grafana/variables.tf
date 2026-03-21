# AWS Managed Grafana Module - Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN (for IRSA — Prometheus remote write to AMP)"
  type        = string
}

variable "eks_oidc_issuer_url" {
  description = "EKS OIDC issuer URL (for IRSA condition)"
  type        = string
}

variable "admin_user_ids" {
  description = "IAM Identity Center user IDs to grant Grafana ADMIN role"
  type        = list(string)
  default     = []
}

variable "viewer_group_ids" {
  description = "IAM Identity Center group IDs to grant Grafana VIEWER role"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default     = {}
}
