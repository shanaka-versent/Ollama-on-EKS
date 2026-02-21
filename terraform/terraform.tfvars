# Ollama on EKS - Default Configuration
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# GPU Instance Options:
# ┌──────────────────┬──────────┬──────────┬───────────────────┬──────────┐
# │ Instance         │ GPUs     │ VRAM     │ Best For          │ Cost/hr  │
# ├──────────────────┼──────────┼──────────┼───────────────────┼──────────┤
# │ g5.xlarge        │ 1x A10G  │ 24GB     │ 7B models         │ ~$1.01   │
# │ g5.2xlarge       │ 1x A10G  │ 24GB     │ 7B-14B models     │ ~$1.21   │
# │ g5.12xlarge      │ 4x A10G  │ 96GB     │ 32B-70B models    │ ~$5.67   │
# │ p4d.24xlarge     │ 8x A100  │ 320GB    │ 70B+ models       │ ~$32.77  │
# └──────────────────┴──────────┴──────────┴───────────────────┴──────────┘

# General
region       = "us-west-2"
environment  = "dev"
project_name = "ollama"

# Network
vpc_cidr           = "10.0.0.0/16"
az_count           = 2
enable_nat_gateway = true

# EKS
kubernetes_version = "1.31"
enable_logging     = false

# System Nodes
system_node_count         = 2
system_node_instance_type = "t3.medium"
system_node_min_count     = 1
system_node_max_count     = 3

# GPU Nodes (g5.12xlarge = 4x NVIDIA A10G, 96GB VRAM — runs 32B models)
enable_gpu_node_pool   = true
gpu_node_count         = 1
gpu_node_instance_type = "g5.12xlarge"
gpu_node_disk_size     = 300
gpu_node_min_count     = 0
gpu_node_max_count     = 2
gpu_capacity_type      = "ON_DEMAND"

# Ollama
ollama_namespace         = "ollama"
ollama_model             = "qwen3-coder:32b"
model_storage_size       = "200Gi"
gpu_count                = 4
ollama_memory_limit      = "96Gi"
ollama_memory_request    = "64Gi"
ollama_cpu_limit         = 16
ollama_cpu_request       = 8
ollama_keep_alive        = "24h"
ollama_num_parallel      = 4
ollama_max_loaded_models = 2
auto_pull_model          = true

# Kong Cloud AI Gateway
# Exposes Ollama via Kong Konnect Dedicated Cloud Gateway with Transit Gateway.
# After terraform apply, ArgoCD auto-deploys Istio + Ollama.
# Then run: scripts/02-generate-certs.sh + scripts/03-setup-cloud-gateway.sh
enable_kong               = true
kong_cloud_gateway_cidr   = "192.168.0.0/16"

# ArgoCD GitOps
# ArgoCD watches argocd/apps/ in the Git repo and deploys everything automatically.
git_repo_url         = "https://github.com/shanaka-versent/Ollama-on-EKS"
argocd_chart_version = "7.7.16"

# Tags
tags = {
  Project   = "Ollama-Private-LLM"
  Purpose   = "Private-LLM-on-EKS"
  ManagedBy = "Terraform"
}
