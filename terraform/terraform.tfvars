# Ollama on EKS - Stack A (Air-Gapped) Configuration
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Stack A: Fully air-gapped — all inference runs on local Ollama/Qwen.
#          Zero external API calls. No Bedrock. No internet egress from pods.
#          Best for defence, healthcare, government engagements.
#
# GPU Instance Options:
# ┌──────────────────┬──────────┬──────────┬───────────────────┬──────────┐
# │ Instance         │ GPUs     │ VRAM     │ Best For          │ Cost/hr  │
# ├──────────────────┼──────────┼──────────┼───────────────────┼──────────┤
# │ g5.xlarge        │ 1x A10G  │ 24GB     │ Tier 1/2 models   │ ~$1.01   │
# │ g5.2xlarge       │ 1x A10G  │ 24GB     │ Tier 1/2 models   │ ~$1.21   │
# │ g5.12xlarge      │ 4x A10G  │ 96GB     │ Tier 3 flagship   │ ~$5.67   │
# └──────────────────┴──────────┴──────────┴───────────────────┴──────────┘

# General
region       = "ap-southeast-2"
environment  = "dev"
project_name = "ollama"

# Network
vpc_cidr           = "10.0.0.0/16"
az_count           = 2
enable_nat_gateway = true

# EKS
kubernetes_version = "1.31"
enable_logging     = false

# All nodes managed by EKS Auto Mode (Karpenter).
# System nodes provision via built-in "system" pool (c6g.large Bottlerocket).
# GPU instances (g5.xlarge/g5.12xlarge) provision automatically when pods
# request nvidia.com/gpu. Spot preferred with on-demand fallback.

# Ollama — Flagship model (Tier 3)
ollama_namespace         = "ollama"
ollama_model             = "qwen3.5:27b"
model_storage_size       = "200Gi"
gpu_count                = 1
ollama_memory_limit      = "24Gi"
ollama_memory_request    = "16Gi"
ollama_cpu_limit         = 4
ollama_cpu_request       = 2
ollama_keep_alive        = "24h"
ollama_num_parallel      = 4
ollama_max_loaded_models = 1
auto_pull_model          = true

# Bedrock Integration — DISABLED for Stack A (air-gapped)
# Set to true only for Stack B (hybrid mode with sanitised Bedrock calls)
enable_bedrock = false

# NLB (created by Istio Gateway via ArgoCD — set after first deploy)
nlb_arn      = ""
nlb_dns_name = ""

# CloudFront + WAF + API Gateway
# Client → CloudFront (WAF) → API Gateway → VPC Link → NLB → Istio → Ollama
api_key_required      = true
throttle_rate         = 10
throttle_burst        = 20
waf_rate_limit        = 2000
waf_geo_countries     = ["AU", "US"]
waf_enable_bot_control = false

# CloudFront domain (set after first apply — used by Cognito callback URLs)
cloudfront_domain = ""

# Cognito Authentication (Open WebUI)
# Cognito handles all user management: signup, login, MFA, role assignment.
# Initial admin receives temporary password via email.
cognito_admin_email        = "shanaka.jayasundera@versent.com.au"
cognito_notification_email = "shanaka.jayasundera@versent.com.au"

# ArgoCD GitOps
# ArgoCD watches argocd/apps/ in the Git repo and deploys everything automatically.
git_repo_url         = "https://github.com/shanaka-versent/Ollama-on-EKS"
argocd_chart_version = "7.7.16"

# Tags
tags = {
  Project   = "Ollama-Private-LLM"
  Purpose   = "Private-LLM-on-EKS"
  Stack     = "A-AirGapped"
  ManagedBy = "Terraform"
}
