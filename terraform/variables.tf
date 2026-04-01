# Ollama on EKS - Terraform Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

# ==============================================================================
# GENERAL
# ==============================================================================

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "ollama"
}

# ==============================================================================
# NETWORK
# ==============================================================================

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones"
  type        = number
  default     = 2
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets"
  type        = bool
  default     = true
}

# ==============================================================================
# EKS CLUSTER
# ==============================================================================

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "enable_logging" {
  description = "Enable EKS control plane logging"
  type        = bool
  default     = false
}

# All nodes managed by EKS Auto Mode (Karpenter).
# System nodes provision via built-in "system" pool.
# GPU instances provision automatically when pods request nvidia.com/gpu.
# No manual node group variables needed.

# ==============================================================================
# OLLAMA CONFIGURATION
# ==============================================================================

variable "ollama_namespace" {
  description = "Kubernetes namespace for Ollama"
  type        = string
  default     = "ollama"
}

variable "ollama_model" {
  description = "Model to auto-pull (e.g., qwen3.5:122b-a10b, qwen3-coder:30b-a3b, qwen3.5:27b)"
  type        = string
  default     = "qwen3.5:122b-a10b"
}

variable "model_storage_size" {
  description = "PVC size for model storage"
  type        = string
  default     = "200Gi"
}

variable "gpu_count" {
  description = "Number of GPUs allocated to Ollama (match instance type: g5.xlarge=1, g5.12xlarge=4)"
  type        = number
  default     = 4
}

variable "ollama_memory_limit" {
  description = "Ollama container memory limit"
  type        = string
  default     = "96Gi"
}

variable "ollama_memory_request" {
  description = "Ollama container memory request"
  type        = string
  default     = "64Gi"
}

variable "ollama_cpu_limit" {
  description = "Ollama container CPU limit"
  type        = number
  default     = 16
}

variable "ollama_cpu_request" {
  description = "Ollama container CPU request"
  type        = number
  default     = 8
}

variable "ollama_keep_alive" {
  description = "How long to keep models loaded in memory"
  type        = string
  default     = "24h"
}

variable "ollama_num_parallel" {
  description = "Number of parallel inference requests"
  type        = number
  default     = 4
}

variable "ollama_max_loaded_models" {
  description = "Maximum models loaded simultaneously"
  type        = number
  default     = 1
}

variable "auto_pull_model" {
  description = "Automatically pull the model after deployment"
  type        = bool
  default     = true
}

# ==============================================================================
# API GATEWAY
# ==============================================================================

variable "nlb_arn" {
  description = "ARN of the internal NLB (created by Istio Gateway via LB Controller, used for REST API VPC Link)"
  type        = string
  default     = ""
}

variable "nlb_dns_name" {
  description = "DNS name of the internal NLB"
  type        = string
  default     = ""
}

variable "api_key_required" {
  description = "Require x-api-key header — enables native usage plans + API key management via Console"
  type        = bool
  default     = true
}

variable "throttle_rate" {
  description = "API Gateway requests per second rate limit"
  type        = number
  default     = 10
}

variable "throttle_burst" {
  description = "API Gateway burst limit for requests"
  type        = number
  default     = 20
}

# ==============================================================================
# CLOUDFRONT + WAF
# ==============================================================================

variable "waf_allowed_ips" {
  description = "CIDR ranges allowed through WAF IP allowlist (corporate IPs)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "waf_rate_limit" {
  description = "WAF rate limit — requests per 5-minute window per IP"
  type        = number
  default     = 2000
}

variable "waf_geo_countries" {
  description = "Allowed country codes for WAF geo-blocking"
  type        = list(string)
  default     = ["AU", "US"]
}

variable "waf_enable_bot_control" {
  description = "Enable AWS Bot Control managed rule group (~$10/mo)"
  type        = bool
  default     = false
}

variable "enable_origin_lockdown" {
  description = "Enable CloudFront → API Gateway origin lockdown (blocks direct API Gateway access)"
  type        = bool
  default     = true
}

variable "cloudfront_domain" {
  description = "CloudFront domain name (set after first apply, used for portal Cognito callbacks)"
  type        = string
  default     = ""
}

# ==============================================================================
# BEDROCK INTEGRATION (Stack B — Hybrid Mode Only)
# ==============================================================================

variable "enable_bedrock" {
  description = "Enable Bedrock integration (Stack B hybrid mode). Set false for Stack A (air-gapped)."
  type        = bool
  default     = false
}

# ==============================================================================
# ARGOCD GITOPS
# ==============================================================================

variable "git_repo_url" {
  description = "Git repository URL for ArgoCD to sync (public repo — no credentials needed)"
  type        = string
  default     = "https://github.com/shanaka-versent/Ollama-on-EKS"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version (argo-cd chart from argoproj.github.io/argo-helm)"
  type        = string
  default     = "7.7.16"
}

# ==============================================================================
# AWS MANAGED GRAFANA (AMG — SSO via IAM Identity Center)
# ==============================================================================

variable "enable_managed_grafana" {
  description = "Enable AWS Managed Grafana ($9/editor/month). Default: false (uses in-cluster Grafana). Set true for production."
  type        = bool
  default     = false
}

variable "amp_remote_write_endpoint" {
  description = "Shared AMP remote-write endpoint. If set, Prometheus writes to this AMP (from shared-infra). If empty, metrics stay in-cluster only."
  type        = string
  default     = ""
}

variable "grafana_admin_user_ids" {
  description = "IAM Identity Center user IDs to grant Grafana ADMIN role"
  type        = list(string)
  default     = []
}

variable "grafana_viewer_group_ids" {
  description = "IAM Identity Center group IDs to grant Grafana VIEWER role"
  type        = list(string)
  default     = []
}

# ==============================================================================
# COGNITO AUTHENTICATION (Open WebUI)
# ==============================================================================

variable "cognito_admin_email" {
  description = "Email for the initial admin user (receives temporary password)"
  type        = string
}

variable "cognito_notification_email" {
  description = "Email to receive new user signup notifications"
  type        = string
}

# ==============================================================================
# OBSERVABILITY
# ==============================================================================

variable "prometheus_retention_days" {
  description = "Number of days to retain Prometheus data"
  type        = number
  default     = 15
}

variable "prometheus_storage_size" {
  description = "Size of Prometheus persistent volume"
  type        = string
  default     = "50Gi"
}

variable "alert_email" {
  description = "Email address for alert notifications (spot interruption, on-demand fallback, GPU termination) via SNS"
  type        = string
  default     = ""
}

# ==============================================================================
# TAGS
# ==============================================================================

variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default = {
    Project   = "Ollama-Private-LLM"
    Purpose   = "Private-LLM-on-EKS"
    ManagedBy = "Terraform"
  }
}
