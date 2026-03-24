# API Key Portal Module — Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cognito_user_pool_id" {
  description = "Cognito User Pool ID (ollama-webui pool)"
  type        = string
}

variable "cognito_domain" {
  description = "Cognito hosted UI domain URL"
  type        = string
}

variable "cloudfront_domain" {
  description = "CloudFront distribution domain name"
  type        = string
}

variable "rest_api_id" {
  description = "Existing API Gateway REST API ID"
  type        = string
}

variable "rest_api_root_resource_id" {
  description = "Root resource ID of the existing REST API"
  type        = string
}

variable "rest_api_execution_arn" {
  description = "Execution ARN of the existing REST API"
  type        = string
}

variable "usage_plan_id" {
  description = "API Gateway Usage Plan ID for associating new keys"
  type        = string
}

variable "key_expiry_days" {
  description = "Default API key expiry in days (0 = no expiry)"
  type        = number
  default     = 90
}

variable "max_keys_per_user" {
  description = "Maximum API keys allowed per user"
  type        = number
  default     = 5
}

variable "signup_client_id" {
  description = "Public Cognito app client ID for signup form (no secret)"
  type        = string
  default     = ""
}

variable "cognito_client_id" {
  description = "Cognito OAuth app client ID (webui client — for auth proxy InitiateAuth)"
  type        = string
}

variable "cognito_client_secret" {
  description = "Cognito OAuth app client secret (webui client — for SECRET_HASH computation)"
  type        = string
  sensitive   = true
}

variable "eks_cluster_name" {
  description = "EKS cluster name (for GPU controller Lambda)"
  type        = string
}

variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default     = {}
}
