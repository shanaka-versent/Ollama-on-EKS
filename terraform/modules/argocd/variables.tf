# ArgoCD Module Variables

variable "namespace" {
  description = "Kubernetes namespace for ArgoCD"
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version (argo-cd chart)"
  type        = string
  default     = "7.7.16"
}

variable "git_repo_url" {
  description = "Git repository URL for ArgoCD to sync (must be accessible without credentials for public repos)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (used for context in output)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}
