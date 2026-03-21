# cert-manager Module — Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "namespace" {
  description = "cert-manager namespace"
  value       = "cert-manager"
}

output "helm_release_name" {
  description = "Helm release name"
  value       = helm_release.cert_manager.name
}

output "helm_release_status" {
  description = "Helm release status"
  value       = helm_release.cert_manager.status
}
