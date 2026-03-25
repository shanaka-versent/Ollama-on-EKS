# API Gateway Module — Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "api_endpoint" {
  description = "API Gateway invoke URL (stage endpoint)"
  value       = aws_api_gateway_stage.prod.invoke_url
}

output "api_id" {
  description = "REST API ID"
  value       = aws_api_gateway_rest_api.ollama.id
}

output "api_execution_arn" {
  description = "API Gateway execution ARN"
  value       = aws_api_gateway_rest_api.ollama.execution_arn
}

output "vpc_link_id" {
  description = "VPC Link ID"
  value       = local.nlb_available ? aws_api_gateway_vpc_link.ollama[0].id : null
}

# --- API Key Outputs ---

output "api_key_id" {
  description = "ID of the initial API key (retrieve value via Console or CLI)"
  value       = var.api_key_required ? aws_api_gateway_api_key.initial[0].id : null
}

output "api_key_value" {
  description = "Value of the initial API key"
  value       = var.api_key_required ? aws_api_gateway_api_key.initial[0].value : null
  sensitive   = true
}

output "usage_plan_id" {
  description = "Usage plan ID (for adding keys via Console)"
  value       = var.api_key_required ? aws_api_gateway_usage_plan.standard[0].id : null
}

output "root_resource_id" {
  description = "REST API root resource ID (for adding portal resources)"
  value       = aws_api_gateway_rest_api.ollama.root_resource_id
}

output "deployment_trigger_hash" {
  description = "Hash that changes when API Gateway routes change, used by portal module to trigger redeployment"
  value = sha1(jsonencode([
    aws_api_gateway_method.chat_completions,
    aws_api_gateway_method.api_tags,
  ]))
}
