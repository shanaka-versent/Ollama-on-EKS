# AWS Managed Grafana Module - Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "grafana_workspace_id" {
  description = "Managed Grafana workspace ID"
  value       = aws_grafana_workspace.ollama.id
}

output "grafana_endpoint" {
  description = "Managed Grafana workspace URL (browser access, SSO login)"
  value       = "https://${aws_grafana_workspace.ollama.endpoint}"
}

output "amp_workspace_id" {
  description = "AMP workspace ID"
  value       = aws_prometheus_workspace.ollama.id
}

output "amp_remote_write_endpoint" {
  description = "AMP remote write endpoint (configure in kube-prometheus-stack)"
  value       = "${aws_prometheus_workspace.ollama.prometheus_endpoint}api/v1/remote_write"
}

output "amp_query_endpoint" {
  description = "AMP query endpoint (for Grafana datasource)"
  value       = aws_prometheus_workspace.ollama.prometheus_endpoint
}

output "prometheus_remote_write_role_arn" {
  description = "IRSA role ARN for Prometheus remote write to AMP"
  value       = aws_iam_role.prometheus_remote_write.arn
}
