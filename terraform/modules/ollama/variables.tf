# Ollama Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "namespace" {
  description = "Kubernetes namespace for Ollama"
  type        = string
  default     = "ollama"
}

# Storage
variable "model_storage_size" {
  description = "PVC size for model storage (enough for multiple large models)"
  type        = string
  default     = "200Gi"
}

# NVIDIA Device Plugin
variable "nvidia_plugin_version" {
  description = "NVIDIA device plugin Helm chart version"
  type        = string
  default     = "0.17.0"
}

# Ollama Deployment
variable "ollama_replicas" {
  description = "Number of Ollama replicas"
  type        = number
  default     = 1
}

variable "ollama_image_tag" {
  description = "Ollama container image tag"
  type        = string
  default     = "latest"
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
  description = "Maximum number of models loaded in memory simultaneously"
  type        = number
  default     = 2
}

# GPU Resources
variable "gpu_count" {
  description = "Number of GPUs to allocate to Ollama (4 for g5.12xlarge)"
  type        = number
  default     = 4
}

variable "ollama_memory_limit" {
  description = "Memory limit for Ollama container"
  type        = string
  default     = "96Gi"
}

variable "ollama_memory_request" {
  description = "Memory request for Ollama container"
  type        = string
  default     = "64Gi"
}

variable "ollama_cpu_limit" {
  description = "CPU limit for Ollama container"
  type        = number
  default     = 16
}

variable "ollama_cpu_request" {
  description = "CPU request for Ollama container"
  type        = number
  default     = 8
}

# Model Auto-Pull
variable "auto_pull_model" {
  description = "Automatically pull the model after deployment"
  type        = bool
  default     = true
}

variable "ollama_model" {
  description = "Model to auto-pull (e.g., qwen2.5-coder:32b, llama3.1:70b)"
  type        = string
  default     = "qwen2.5-coder:32b"
}
