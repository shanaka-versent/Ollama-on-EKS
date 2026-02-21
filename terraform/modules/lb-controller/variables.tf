# AWS Load Balancer Controller Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "iam_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller (IRSA)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "chart_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "1.7.1"
}

variable "cluster_dependency" {
  description = "Dependency to ensure EKS cluster is ready"
  type        = any
  default     = null
}
