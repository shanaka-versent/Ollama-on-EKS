# Bedrock Integration Module — Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the Bedrock VPC endpoint"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for VPC endpoint placement"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks of private subnets (for security group ingress)"
  type        = list(string)
}

variable "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA"
  type        = string
}

variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default     = {}
}
