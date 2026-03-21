variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "grafana_admin_password" {
  description = "Admin password for Grafana"
  type        = string
  sensitive   = true
}

variable "prometheus_retention_days" {
  description = "Number of days to retain Prometheus data"
  type        = number
  default     = 15
}

variable "prometheus_storage_size" {
  description = "Size of Prometheus persistent volume"
  type        = string
  default     = "50Gi"
}

variable "grafana_storage_size" {
  description = "Size of Grafana persistent volume"
  type        = string
  default     = "10Gi"
}

variable "gpu_node_selector_key" {
  description = "Node selector key for GPU nodes where DCGM exporter should run"
  type        = string
  default     = "workload-type"
}

variable "gpu_node_selector_value" {
  description = "Node selector value for GPU nodes"
  type        = string
  default     = "gpu-inference"
}

variable "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN (for IRSA — Grafana CloudWatch access)"
  type        = string
  default     = ""
}

variable "eks_oidc_issuer_url" {
  description = "EKS OIDC issuer URL (for IRSA condition)"
  type        = string
  default     = ""
}

variable "enable_grafana" {
  description = "Enable in-cluster Grafana. Set false when using AWS Managed Grafana."
  type        = bool
  default     = true
}

variable "amp_remote_write_endpoint" {
  description = "AMP remote write endpoint. When set, Prometheus sends all metrics to AMP for AMG to read."
  type        = string
  default     = ""
}

variable "amp_remote_write_role_arn" {
  description = "IRSA role ARN for Prometheus remote write to AMP."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
