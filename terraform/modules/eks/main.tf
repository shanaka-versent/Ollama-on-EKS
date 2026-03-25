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

  # Auto Mode requires API or API_AND_CONFIG_MAP authentication mode
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Auto Mode requires disabling self-managed addons (vpc-cni, coredns, kube-proxy)
  # so they don't conflict with Auto Mode's managed versions.
  bootstrap_self_managed_addons = false

  # Auto Mode — AWS manages Karpenter, NVIDIA device plugin, EBS CSI, and LB controller.
  # GPU nodes only provision when a pod requests nvidia.com/gpu resources.
  compute_config {
    enabled       = true
    node_pools    = ["system"]  # EKS Auto Mode requires at least one built-in pool when nodeRoleArn is set. Deploy script patches this pool's limits to 0 CPU/0 memory to prevent c6g.large provisioning.
    node_role_arn = var.node_role_arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
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

# System Node Group — REMOVED: Auto Mode manages all nodes via Karpenter.
# Auto Mode's built-in "system" pool provisions system nodes automatically.
# Managed node groups are incompatible with Auto Mode (DaemonSets like vpc-cni
# show DESIRED=0 on Bottlerocket Auto Mode nodes, blocking managed node registration).

# GPU Node Group — REMOVED: Auto Mode manages GPU nodes via Karpenter.
# GPU instances (g5.xlarge/g5.12xlarge) provision automatically when pods
# request nvidia.com/gpu resources. Spot with on-demand fallback is the default.

# EKS Addons — Auto Mode manages networking and storage natively, but explicit
# addon resources ensure version pinning and Terraform lifecycle management.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}
