# cert-manager Module — Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.17.1"
}

variable "eks_cluster_endpoint" {
  description = "EKS cluster endpoint (used as dependency)"
  type        = string
}
