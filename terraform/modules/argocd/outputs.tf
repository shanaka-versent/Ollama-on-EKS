# ArgoCD Module Outputs

output "namespace" {
  description = "ArgoCD namespace"
  value       = helm_release.argocd.namespace
}

output "admin_password_command" {
  description = "Command to retrieve the initial ArgoCD admin password"
  value       = "kubectl -n ${helm_release.argocd.namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "port_forward_command" {
  description = "Command to access the ArgoCD UI locally"
  value       = "kubectl port-forward svc/argocd-server -n ${helm_release.argocd.namespace} 8080:443"
}
