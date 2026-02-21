# Ollama on EKS - Main Terraform Configuration
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Architecture Layers:
# ===================
# Layer 1: Cloud Foundations (Terraform)
#   - VPC, Subnets, NAT Gateway, Internet Gateway
#
# Layer 2: Base EKS Cluster Setup (Terraform)
#   - IAM Roles (Cluster, Node, EBS CSI)
#   - EKS Cluster, Node Groups (System + GPU)
#   - OIDC Provider for IRSA
#   - EKS Addons (VPC-CNI, CoreDNS, kube-proxy, EBS CSI)
#
# Layer 3: Ollama Deployment (Terraform via Kubernetes Provider)
#   - NVIDIA Device Plugin
#   - GP3 StorageClass + PVC
#   - Ollama Deployment (GPU-accelerated)
#   - ClusterIP Service (internal only)
#   - NetworkPolicy (locked down)
#   - Model Loader Job (auto-pulls model)

locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  cluster_name = "eks-${local.name_prefix}"
}

# ==============================================================================
# LAYER 1: CLOUD FOUNDATIONS
# ==============================================================================

module "vpc" {
  source = "./modules/vpc"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  cluster_name       = local.cluster_name
  enable_nat_gateway = var.enable_nat_gateway
  tags               = var.tags
}

# ==============================================================================
# LAYER 2: BASE EKS CLUSTER SETUP
# ==============================================================================

# IAM Module - Cluster and Node roles
module "iam" {
  source = "./modules/iam"

  name_prefix = local.name_prefix
  tags        = var.tags
}

# EKS Module - Kubernetes cluster with System + GPU node groups
module "eks" {
  source = "./modules/eks"

  name_prefix        = local.name_prefix
  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version
  cluster_role_arn   = module.iam.cluster_role_arn
  node_role_arn      = module.iam.node_role_arn

  # Network
  subnet_ids      = concat(module.vpc.public_subnet_ids, module.vpc.private_subnet_ids)
  node_subnet_ids = module.vpc.private_subnet_ids

  # System Node Pool
  system_node_count         = var.system_node_count
  system_node_instance_type = var.system_node_instance_type
  system_node_min_count     = var.system_node_min_count
  system_node_max_count     = var.system_node_max_count

  # GPU Node Pool
  enable_gpu_node_pool   = var.enable_gpu_node_pool
  gpu_node_count         = var.gpu_node_count
  gpu_node_instance_type = var.gpu_node_instance_type
  gpu_node_disk_size     = var.gpu_node_disk_size
  gpu_node_min_count     = var.gpu_node_min_count
  gpu_node_max_count     = var.gpu_node_max_count
  gpu_capacity_type      = var.gpu_capacity_type

  # Logging
  enable_logging = var.enable_logging

  tags = var.tags
}

# IAM for EBS CSI Driver (IRSA - needs OIDC from EKS cluster)
module "iam_ebs_csi" {
  source = "./modules/iam"

  name_prefix         = "${local.name_prefix}-ebs-csi"
  create_ebs_csi_role = true
  oidc_provider_arn   = module.eks.oidc_provider_arn
  oidc_provider_url   = module.eks.oidc_provider_url
  tags                = var.tags
}

# EBS CSI Driver Addon (installed after EKS + IRSA role are ready)
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.iam_ebs_csi.ebs_csi_role_arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

# ==============================================================================
# LAYER 3: OLLAMA DEPLOYMENT
# ==============================================================================

module "ollama" {
  source = "./modules/ollama"

  namespace     = var.ollama_namespace
  ollama_model  = var.ollama_model

  # Storage
  model_storage_size = var.model_storage_size

  # GPU Resources (match to your instance type)
  gpu_count             = var.gpu_count
  ollama_memory_limit   = var.ollama_memory_limit
  ollama_memory_request = var.ollama_memory_request
  ollama_cpu_limit      = var.ollama_cpu_limit
  ollama_cpu_request    = var.ollama_cpu_request

  # Ollama Config
  ollama_keep_alive        = var.ollama_keep_alive
  ollama_num_parallel      = var.ollama_num_parallel
  ollama_max_loaded_models = var.ollama_max_loaded_models

  # Model auto-pull
  auto_pull_model = var.auto_pull_model

  depends_on = [module.eks, aws_eks_addon.ebs_csi]
}
