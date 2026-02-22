# EKS Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "cluster_role_arn" {
  description = "IAM role ARN for EKS cluster"
  type        = string
}

variable "node_role_arn" {
  description = "IAM role ARN for EKS nodes"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for EKS cluster"
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Subnet IDs for EKS nodes (system node group uses all)"
  type        = list(string)
}

variable "gpu_subnet_ids" {
  description = "Subnet IDs for GPU nodes. Pin to a single AZ to match EBS volume affinity. Defaults to node_subnet_ids if not set."
  type        = list(string)
  default     = []
}

variable "cluster_security_group_ids" {
  description = "Additional security group IDs for cluster"
  type        = list(string)
  default     = []
}

variable "endpoint_private_access" {
  description = "Enable private API endpoint"
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable public API endpoint"
  type        = bool
  default     = true
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

variable "system_node_disk_size" {
  description = "Disk size for system nodes (GB)"
  type        = number
  default     = 50
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

variable "system_capacity_type" {
  description = "Capacity type for system nodes (ON_DEMAND or SPOT)"
  type        = string
  default     = "ON_DEMAND"
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
  description = "Instance type for GPU nodes"
  type        = string
  default     = "g5.12xlarge"
}

variable "gpu_ami_type" {
  description = "AMI type for GPU nodes (AL2_x86_64_GPU for NVIDIA support)"
  type        = string
  default     = "AL2_x86_64_GPU"
}

variable "gpu_node_disk_size" {
  description = "Disk size for GPU nodes (GB) - needs space for container images"
  type        = number
  default     = 300
}

variable "gpu_node_min_count" {
  description = "Minimum GPU nodes (set to 0 for cost savings when not in use)"
  type        = number
  default     = 0
}

variable "gpu_node_max_count" {
  description = "Maximum GPU nodes"
  type        = number
  default     = 2
}

variable "gpu_capacity_type" {
  description = "Capacity type for GPU nodes (ON_DEMAND or SPOT)"
  type        = string
  default     = "ON_DEMAND"
}

# Logging
variable "enable_logging" {
  description = "Enable EKS control plane logging"
  type        = bool
  default     = false
}

variable "cluster_log_types" {
  description = "EKS cluster log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
