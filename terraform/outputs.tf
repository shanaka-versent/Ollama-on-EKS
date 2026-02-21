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
# LAYER 3: OLLAMA
# ==============================================================================

output "ollama_namespace" {
  description = "Ollama Kubernetes namespace"
  value       = module.ollama.namespace
}

output "ollama_cluster_url" {
  description = "Ollama in-cluster URL"
  value       = module.ollama.cluster_url
}

output "ollama_port_forward_command" {
  description = "Command to tunnel Ollama to your local machine"
  value       = module.ollama.port_forward_command
}

# ==============================================================================
# KONG CLOUD AI GATEWAY (Transit Gateway)
# ==============================================================================

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = module.vpc.vpc_cidr
}

output "transit_gateway_id" {
  description = "Transit Gateway ID — provide to Konnect when attaching Cloud Gateway network"
  value       = var.enable_kong ? aws_ec2_transit_gateway.kong[0].id : null
}

output "transit_gateway_arn" {
  description = "Transit Gateway ARN"
  value       = var.enable_kong ? aws_ec2_transit_gateway.kong[0].arn : null
}

output "ram_share_arn" {
  description = "RAM Resource Share ARN — provide to Konnect for Transit Gateway attachment"
  value       = var.enable_kong ? aws_ram_resource_share.kong_tgw[0].arn : null
}

output "kong_cloud_gateway_setup_command" {
  description = "Command to set up Kong Cloud AI Gateway"
  value = (var.enable_kong ? <<-EOT
    # 1. Install Istio + Gateway API:
    ./scripts/01-install-istio.sh

    # 2. Generate TLS certs for Istio Gateway:
    ./scripts/02-generate-certs.sh

    # 3. Apply Gateway + HTTPRoutes:
    kubectl apply -f k8s/gateway.yaml
    kubectl apply -f k8s/httproutes.yaml

    # 4. Set up Kong Konnect Cloud AI Gateway:
    #    (ensure .env has KONNECT_REGION and KONNECT_TOKEN)
    ./scripts/03-setup-cloud-gateway.sh

    # 5. Discover NLB endpoint + configure Kong routes:
    ./scripts/04-post-setup.sh

    # Auto-populated from Terraform:
    #   TRANSIT_GATEWAY_ID = ${aws_ec2_transit_gateway.kong[0].id}
    #   RAM_SHARE_ARN      = ${aws_ram_resource_share.kong_tgw[0].arn}
    #   EKS_VPC_CIDR       = ${module.vpc.vpc_cidr}
  EOT
    : "Kong not enabled"
  )
}

# ==============================================================================
# QUICK START COMMANDS
# ==============================================================================

output "connect_to_ollama" {
  description = "Steps to connect Claude Code to your private Ollama"
  value       = <<-EOT

    ================================================
    Connect Claude Code to Private EKS Ollama
    ================================================

    1. Get cluster credentials:
       ${module.eks.cluster_name != "" ? "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}" : ""}

    2. Start the tunnel (keep this terminal open):
       ${module.ollama.port_forward_command}

    3. In another terminal, run Claude Code:
       ANTHROPIC_BASE_URL=http://localhost:11434 \
       ANTHROPIC_AUTH_TOKEN=ollama \
       ANTHROPIC_API_KEY="" \
       CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
       claude --model ${var.ollama_model}

    ================================================
    Cost Management
    ================================================

    Scale GPU to 0 (stop billing):
       kubectl scale deployment ollama -n ${var.ollama_namespace} --replicas=0
       aws eks update-nodegroup-config --cluster-name ${module.eks.cluster_name} \
         --nodegroup-name ${module.eks.node_group_gpu_name != null ? module.eks.node_group_gpu_name : "gpu-nodes"} \
         --scaling-config minSize=0,maxSize=2,desiredSize=0 \
         --region ${var.region}

    Scale GPU back up:
       aws eks update-nodegroup-config --cluster-name ${module.eks.cluster_name} \
         --nodegroup-name ${module.eks.node_group_gpu_name != null ? module.eks.node_group_gpu_name : "gpu-nodes"} \
         --scaling-config minSize=0,maxSize=2,desiredSize=1 \
         --region ${var.region}
       kubectl scale deployment ollama -n ${var.ollama_namespace} --replicas=1

  EOT
}
