# CDN + WAF Module — Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "api_gateway_endpoint" {
  description = "API Gateway invoke URL (used as CloudFront origin)"
  type        = string
}

variable "allowed_ips" {
  description = "List of CIDR ranges allowed through WAF IP allowlist"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Override with corporate CIDRs
}

variable "rate_limit" {
  description = "WAF rate limit — requests per 5-minute window per IP"
  type        = number
  default     = 100
}

variable "geo_countries" {
  description = "Allowed country codes for geo-blocking"
  type        = list(string)
  default     = ["AU", "US"]
}

variable "enable_bot_control" {
  description = "Enable AWS Bot Control managed rule group (~$10/mo)"
  type        = bool
  default     = false
}

variable "origin_verify_secret" {
  description = "Shared secret header value for CloudFront → API Gateway origin lockdown. Prevents direct API Gateway access."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default     = {}
}
