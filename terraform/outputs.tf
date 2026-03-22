# Ollama on EKS - Terraform Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

# ==============================================================================
# LAYER 1: CLOUD FOUNDATIONS
# ==============================================================================

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = module.vpc.vpc_cidr
}

# ==============================================================================
# LAYER 2: EKS CLUSTER
# ==============================================================================

output "eks_cluster_name" {
  description = "EKS Cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS Cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "eks_get_credentials_command" {
  description = "Command to get EKS credentials"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "eks_oidc_issuer_url" {
  description = "EKS OIDC issuer URL"
  value       = module.eks.oidc_issuer_url
}

output "gpu_node_group_name" {
  description = "GPU node group name (for scaling)"
  value       = module.eks.node_group_gpu_name
}

# ==============================================================================
# ARGOCD BOOTSTRAP
# ==============================================================================

output "argocd_admin_password_command" {
  description = "Command to retrieve the ArgoCD initial admin password"
  value       = module.argocd.admin_password_command
}

output "argocd_ui_command" {
  description = "Command to access the ArgoCD UI at https://localhost:8080"
  value       = module.argocd.port_forward_command
}

output "argocd_check_apps" {
  description = "Command to check ArgoCD application sync status"
  value       = "kubectl get applications -n argocd"
}

# ==============================================================================
# OLLAMA
# ==============================================================================

output "ollama_namespace" {
  description = "Ollama Kubernetes namespace (managed by ArgoCD)"
  value       = var.ollama_namespace
}

output "ollama_cluster_url" {
  description = "Ollama in-cluster URL"
  value       = "http://ollama.${var.ollama_namespace}.svc.cluster.local:11434"
}

output "ollama_port_forward_command" {
  description = "Command to tunnel Ollama to your local machine (requires kubectl access)"
  value       = "kubectl port-forward -n ${var.ollama_namespace} svc/ollama 11434:11434"
}

# ==============================================================================
# CLOUDFRONT + WAF + API GATEWAY
# ==============================================================================

output "cloudfront_domain" {
  description = "CloudFront distribution domain name — use this as the Ollama API endpoint"
  value       = module.cdn_waf.cloudfront_domain
}

output "api_gateway_endpoint" {
  description = "API Gateway invoke URL (fronted by CloudFront)"
  value       = module.api_gateway.api_endpoint
}

output "api_key_retrieve_command" {
  description = "Command to retrieve the API key"
  value       = var.api_key_required ? "aws apigateway get-api-key --api-key ${module.api_gateway.api_key_id} --include-value --query value --output text" : "API key auth disabled"
}

output "api_key_id" {
  description = "ID of the initial API key"
  value       = module.api_gateway.api_key_id
}

output "usage_plan_id" {
  description = "Usage plan ID (add keys via Console: API Gateway → Usage Plans)"
  value       = module.api_gateway.usage_plan_id
}

output "api_key_portal_url" {
  description = "URL for self-service API key management portal"
  value       = module.api_key_portal.portal_url
}

# ==============================================================================
# BEDROCK INTEGRATION (Stack B Only)
# ==============================================================================

output "bedrock_vpc_endpoint_id" {
  description = "Bedrock VPC endpoint ID (Stack B only)"
  value       = var.enable_bedrock ? module.bedrock_integration[0].vpc_endpoint_id : null
}

output "bedrock_irsa_role_arn" {
  description = "IRSA role ARN for orchestrator Bedrock access (Stack B only)"
  value       = var.enable_bedrock ? module.bedrock_integration[0].irsa_role_arn : null
}

# ==============================================================================
# OBSERVABILITY
# ==============================================================================

output "grafana_port_forward_command" {
  description = "Command to access Grafana dashboards (in-cluster, when managed Grafana is disabled)"
  value       = "kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
}

output "managed_grafana_url" {
  description = "AWS Managed Grafana URL (SSO login, when enabled)"
  value       = var.enable_managed_grafana ? module.managed_grafana[0].grafana_endpoint : null
}

output "amp_remote_write_endpoint" {
  description = "AMP remote write endpoint (when managed Grafana is enabled)"
  value       = var.enable_managed_grafana ? module.managed_grafana[0].amp_remote_write_endpoint : null
}

# ==============================================================================
# QUICK START COMMANDS
# ==============================================================================

output "connect_to_ollama" {
  description = "Steps to connect to your private Ollama"
  value       = <<-EOT

    ================================================
    Connect to Private EKS Ollama via CloudFront
    ================================================

    ${var.api_key_required ? "0. Get your API key:\n       API_KEY=$(aws apigateway get-api-key --api-key ${module.api_gateway.api_key_id} --include-value --query value --output text)\n" : ""}
    1. Via CloudFront (recommended):
       curl https://${module.cdn_waf.cloudfront_domain}/v1/chat/completions \
         -H "Content-Type: application/json" \
         ${var.api_key_required ? "-H \"x-api-key: $API_KEY\" \\\n         " : ""}-d '{"model": "${var.ollama_model}", "messages": [{"role": "user", "content": "Hello"}]}'

    2. Via kubectl port-forward (direct, no API key needed):
       kubectl port-forward -n ${var.ollama_namespace} svc/ollama 11434:11434
       curl http://localhost:11434/v1/chat/completions \
         -H "Content-Type: application/json" \
         -d '{"model": "${var.ollama_model}", "messages": [{"role": "user", "content": "Hello"}]}'

    ================================================
    Cost Management
    ================================================

    Scale GPU to 0 (stop billing):
       kubectl scale deployment ollama -n ${var.ollama_namespace} --replicas=0

    Scale GPU back up:
       kubectl scale deployment ollama -n ${var.ollama_namespace} --replicas=1

  EOT
}
