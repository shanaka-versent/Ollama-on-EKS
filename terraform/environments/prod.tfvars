# Ollama on EKS — PROD Environment Configuration
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# PROD: Tier 3 flagship (qwen3.5:122b-a10b) on g5.12xlarge (4x A10G, $1.90/hr spot).
# Maximum quality — beats GPT-5 mini on tool use (+30%). For client engagements.
# GPU spot with on-demand fallback. System nodes on t3.large on-demand.
#
# Deploy: terraform apply -var-file=environments/prod.tfvars

# General
region       = "ap-southeast-2"
environment  = "prod"
project_name = "ollama"

# Network
vpc_cidr           = "10.0.0.0/16"
az_count           = 2
enable_nat_gateway = true

# EKS
kubernetes_version = "1.31"
enable_logging     = true

# Ollama — Tier 3 Flagship (PROD)
# g5.12xlarge: 4x A10G (96GB VRAM), 48 vCPU, 192Gi RAM
ollama_namespace         = "ollama"
ollama_model             = "qwen3.5:122b-a10b"
model_storage_size       = "200Gi"
gpu_count                = 4
ollama_memory_limit      = "96Gi"
ollama_memory_request    = "64Gi"
ollama_cpu_limit         = 16
ollama_cpu_request       = 8
ollama_keep_alive        = "24h"
ollama_num_parallel      = 4
ollama_max_loaded_models = 1
auto_pull_model          = true

# Bedrock Integration — DISABLED for Stack A (air-gapped)
# Set to true for Stack B (hybrid mode with sanitised Bedrock calls)
enable_bedrock = false

# NLB (created by Istio Gateway via ArgoCD — set after first deploy)
# These values will differ per environment — update after first deploy
nlb_arn      = ""
nlb_dns_name = ""

# CloudFront + WAF + API Gateway
api_key_required       = true
throttle_rate          = 50
throttle_burst         = 100
waf_rate_limit         = 2000
waf_geo_countries      = ["AU", "US"]
waf_enable_bot_control = false

# CloudFront domain (set after first apply — used by Cognito callback URLs)
cloudfront_domain = ""

# Cognito Authentication (Open WebUI)
cognito_admin_email        = "shanaka.jayasundera@versent.com.au"
cognito_notification_email = "shanaka.jayasundera@versent.com.au"

# ArgoCD GitOps
git_repo_url         = "https://github.com/shanaka-versent/Ollama-on-EKS"
argocd_chart_version = "7.7.16"

# Tags
tags = {
  Project     = "Ollama-Private-LLM"
  Purpose     = "Private-LLM-on-EKS"
  Stack       = "A-AirGapped"
  Environment = "prod"
  ManagedBy   = "Terraform"
}
