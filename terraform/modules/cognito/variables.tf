# Cognito Module — Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "cloudfront_domain" {
  description = "CloudFront distribution domain (used for OAuth callback URLs)"
  type        = string
}

variable "admin_email" {
  description = "Email for the initial admin user"
  type        = string
}

variable "notification_email" {
  description = "Email to receive new user signup notifications"
  type        = string
}

variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default     = {}
}

variable "allowed_email_domains" {
  description = "Comma-separated list of allowed email domains for signup (empty = allow all)"
  type        = string
  default     = ""
}
