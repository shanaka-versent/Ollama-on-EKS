# Ollama Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "namespace" {
  description = "Ollama Kubernetes namespace"
  value       = kubernetes_namespace.ollama.metadata[0].name
}

output "service_name" {
  description = "Ollama Kubernetes service name"
  value       = kubernetes_service.ollama.metadata[0].name
}

output "service_port" {
  description = "Ollama service port"
  value       = 11434
}

output "cluster_url" {
  description = "Ollama in-cluster URL"
  value       = "http://ollama.${var.namespace}.svc:11434"
}

output "port_forward_command" {
  description = "kubectl port-forward command to access Ollama from local machine"
  value       = "kubectl port-forward -n ${var.namespace} svc/ollama 11434:11434"
}
