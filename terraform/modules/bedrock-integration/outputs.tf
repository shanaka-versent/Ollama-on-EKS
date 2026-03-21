# Bedrock Integration Module — Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "vpc_endpoint_id" {
  description = "Bedrock runtime VPC endpoint ID"
  value       = aws_vpc_endpoint.bedrock_runtime.id
}

output "vpc_endpoint_dns" {
  description = "Bedrock runtime VPC endpoint DNS entries"
  value       = aws_vpc_endpoint.bedrock_runtime.dns_entry
}

output "irsa_role_arn" {
  description = "IRSA role ARN for orchestrator Bedrock access"
  value       = module.bedrock_irsa.iam_role_arn
}

output "irsa_role_name" {
  description = "IRSA role name"
  value       = module.bedrock_irsa.iam_role_name
}

output "security_group_id" {
  description = "Security group ID for Bedrock VPC endpoint"
  value       = aws_security_group.bedrock_endpoint.id
}
