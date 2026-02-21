# Ollama on EKS - Terraform Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

# ==============================================================================
# GENERAL
# ==============================================================================

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
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
  default     = "1.31"
}

variable "enable_logging" {
  description = "Enable EKS control plane logging"
  type        = bool
  default     = false
}

# System Node Pool
variable "system_node_count" {
  description = "Number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_instance_type" {
  description = "Instance type for system nodes"
  type        = string
  default     = "t3.medium"
}

variable "system_node_min_count" {
  description = "Minimum system nodes"
  type        = number
  default     = 1
}

variable "system_node_max_count" {
  description = "Maximum system nodes"
  type        = number
  default     = 3
}

# GPU Node Pool
variable "enable_gpu_node_pool" {
  description = "Enable GPU node pool for LLM inference"
  type        = bool
  default     = true
}

variable "gpu_node_count" {
  description = "Number of GPU nodes"
  type        = number
  default     = 1
}

variable "gpu_node_instance_type" {
  description = "GPU instance type (g5.xlarge=1xA10G, g5.12xlarge=4xA10G, p4d.24xlarge=8xA100)"
  type        = string
  default     = "g5.12xlarge"
}

variable "gpu_node_disk_size" {
  description = "Disk size for GPU nodes (GB)"
  type        = number
  default     = 300
}

variable "gpu_node_min_count" {
  description = "Minimum GPU nodes (0 = scale down to save costs)"
  type        = number
  default     = 0
}

variable "gpu_node_max_count" {
  description = "Maximum GPU nodes"
  type        = number
  default     = 2
}

variable "gpu_capacity_type" {
  description = "GPU node capacity type (ON_DEMAND or SPOT for cost savings)"
  type        = string
  default     = "ON_DEMAND"
}

# ==============================================================================
# OLLAMA CONFIGURATION
# ==============================================================================

variable "ollama_namespace" {
  description = "Kubernetes namespace for Ollama"
  type        = string
  default     = "ollama"
}

variable "ollama_model" {
  description = "Model to auto-pull (e.g., qwen2.5-coder:32b, llama3.1:70b, codestral:22b)"
  type        = string
  default     = "qwen2.5-coder:32b"
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
  default     = 2
}

variable "auto_pull_model" {
  description = "Automatically pull the model after deployment"
  type        = bool
  default     = true
}

# ==============================================================================
# KONG CLOUD AI GATEWAY
# ==============================================================================

variable "enable_kong" {
  description = "Enable Kong Cloud AI Gateway (Transit Gateway, LB Controller, Istio prereqs)"
  type        = bool
  default     = true
}

variable "kong_cloud_gateway_cidr" {
  description = "Kong Cloud Gateway CIDR block (do not change unless Kong changes their network)"
  type        = string
  default     = "192.168.0.0/16"
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
