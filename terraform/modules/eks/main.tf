# EKS Module
# @author Shanaka Jayasundera - shanakaj@gmail.com

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = var.cluster_role_arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    security_group_ids      = var.cluster_security_group_ids
  }

  enabled_cluster_log_types = var.enable_logging ? var.cluster_log_types : []

  tags = var.tags
}

# OIDC Provider for IRSA
data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = var.tags
}

# System Node Group (for kube-system, addons, controllers)
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system-${var.name_prefix}"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.node_subnet_ids

  instance_types = [var.system_node_instance_type]
  capacity_type  = var.system_capacity_type
  disk_size      = var.system_node_disk_size

  scaling_config {
    desired_size = var.system_node_count
    min_size     = var.system_node_min_count
    max_size     = var.system_node_max_count
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "system"
  }

  # Taint system nodes so GPU workloads don't land here
  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = var.tags

  depends_on = [aws_eks_cluster.main]
}

# GPU Node Group (for Ollama / LLM inference)
resource "aws_eks_node_group" "gpu" {
  count           = var.enable_gpu_node_pool ? 1 : 0
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "gpu-${var.name_prefix}"
  node_role_arn   = var.node_role_arn
  # Pin GPU nodes to a single AZ to match EBS volume affinity.
  # EBS volumes are AZ-scoped — if the GPU node comes up in a different AZ
  # from the PVC, the pod cannot schedule (volume node affinity conflict).
  subnet_ids = length(var.gpu_subnet_ids) > 0 ? var.gpu_subnet_ids : var.node_subnet_ids
  ami_type   = var.gpu_ami_type

  instance_types = [var.gpu_node_instance_type]
  capacity_type  = var.gpu_capacity_type
  disk_size      = var.gpu_node_disk_size

  scaling_config {
    desired_size = var.gpu_node_count
    min_size     = var.gpu_node_min_count
    max_size     = var.gpu_node_max_count
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role                     = "gpu"
    "nvidia.com/gpu.present" = "true"
  }

  # Taint GPU nodes so only GPU-requesting pods schedule here
  taint {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = var.tags

  depends_on = [aws_eks_cluster.main]
}

# EKS Addons
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.system]
}
