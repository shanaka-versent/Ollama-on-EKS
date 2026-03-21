output "grafana_service_name" {
  description = "Name of the Grafana service for port-forwarding"
  value       = "kube-prometheus-stack-grafana"
}

output "prometheus_service_name" {
  description = "Name of the Prometheus service"
  value       = "kube-prometheus-stack-prometheus"
}

output "grafana_namespace" {
  description = "Namespace where Grafana is deployed"
  value       = "monitoring"
}
