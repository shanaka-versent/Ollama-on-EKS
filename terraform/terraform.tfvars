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

# System Nodes (3 nodes needed for ArgoCD + cert-manager + monitoring stack)
system_node_count         = 3
system_node_instance_type = "t3.medium"
system_node_min_count     = 2
system_node_max_count     = 4

# GPU Nodes (g5.12xlarge = 4x NVIDIA A10G, 96GB VRAM — runs qwen3.5:122b-a10b)
enable_gpu_node_pool   = true
gpu_node_count         = 1
gpu_node_instance_type = "g5.12xlarge"
gpu_node_disk_size     = 300
gpu_node_min_count     = 0
gpu_node_max_count     = 2
gpu_capacity_type      = "ON_DEMAND"

# Ollama — Flagship model (Tier 3)
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
# Set to true only for Stack B (hybrid mode with sanitised Bedrock calls)
enable_bedrock = false

# NLB (created by Istio Gateway via ArgoCD — set after first deploy)
nlb_arn      = "arn:aws:elasticloadbalancing:ap-southeast-2:695418593935:loadbalancer/net/k8s-istioing-ollamaga-d67dab2c37/8a64fd762757025b"
nlb_dns_name = "k8s-istioing-ollamaga-d67dab2c37-8a64fd762757025b.elb.ap-southeast-2.amazonaws.com"

# CloudFront + WAF + API Gateway
# Client → CloudFront (WAF) → API Gateway → VPC Link → NLB → Istio → Ollama
api_key_required      = true
throttle_rate         = 10
throttle_burst        = 20
waf_rate_limit        = 100
waf_geo_countries     = ["AU", "US"]
waf_enable_bot_control = false

# Observability — AWS Managed Grafana (replaces in-cluster Grafana)
# Requires IAM Identity Center (AWS SSO) to be enabled in the account.
# When true: creates AMG workspace + AMP, disables in-cluster Grafana pod.
enable_managed_grafana = true

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
