# API Gateway Module — Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "nlb_arn" {
  description = "ARN of the internal NLB (for VPC Link)"
  type        = string
}

variable "nlb_dns_name" {
  description = "DNS name of the internal NLB"
  type        = string
}

variable "api_key_required" {
  description = "Require x-api-key header — enables usage plan + API key management via Console"
  type        = bool
  default     = true
}

variable "throttle_rate" {
  description = "Requests per second rate limit"
  type        = number
  default     = 10
}

variable "throttle_burst" {
  description = "Burst limit for requests"
  type        = number
  default     = 20
}

variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default     = {}
}
