# Ollama on EKS — DEV Environment Configuration
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# DEV: Tier 1 fallback (qwen3.5:27b) on g5.xlarge (1x A10G, $0.35/hr spot).
# For platform testing, monitoring setup, and infrastructure validation.
# GPU spot with on-demand fallback. System nodes on t3.large on-demand.
#
# Deploy: terraform apply -var-file=environments/dev.tfvars

# General
region       = "ap-southeast-2"
environment  = "dev"
project_name = "ollama"

# Network
vpc_cidr           = "10.0.0.0/16"
az_count           = 2
enable_nat_gateway = true

# EKS
kubernetes_version = "1.34"
enable_logging     = false

# Ollama — Tier 1 Fallback (DEV)
# g5.xlarge: 1x A10G (24GB VRAM), 4 vCPU, 16Gi RAM
ollama_namespace         = "ollama"
ollama_model             = "qwen3.5:27b"
model_storage_size       = "200Gi"
gpu_count                = 1
ollama_memory_limit      = "14Gi"
ollama_memory_request    = "12Gi"
ollama_cpu_limit         = 3
ollama_cpu_request       = 2
ollama_keep_alive        = "24h"
ollama_num_parallel      = 4
ollama_max_loaded_models = 1
auto_pull_model          = true

# Bedrock Integration — DISABLED for Stack A (air-gapped)
enable_bedrock = false

# NLB (created by Istio Gateway via ArgoCD — set after first deploy)
nlb_arn      = ""
nlb_dns_name = ""

# CloudFront + WAF + API Gateway
api_key_required       = true
throttle_rate          = 10
throttle_burst         = 20
waf_rate_limit         = 2000
waf_geo_countries      = ["AU", "US"]
waf_enable_bot_control = false

# CloudFront domain (set after first apply — used by Cognito callback URLs)
cloudfront_domain = "d1eg49k9r220u8.cloudfront.net"

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
  Environment = "dev"
  ManagedBy   = "Terraform"
}
