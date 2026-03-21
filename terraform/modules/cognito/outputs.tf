# Cognito Module — Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.ollama.id
}

output "user_pool_endpoint" {
  description = "Cognito User Pool OIDC endpoint"
  value       = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.ollama.id}"
}

output "client_id" {
  description = "OAuth client ID for Open WebUI"
  value       = aws_cognito_user_pool_client.webui.id
}

output "client_secret" {
  description = "OAuth client secret for Open WebUI"
  value       = aws_cognito_user_pool_client.webui.client_secret
  sensitive   = true
}

output "cognito_domain" {
  description = "Cognito hosted UI domain"
  value       = "https://${aws_cognito_user_pool_domain.ollama.domain}.auth.${data.aws_region.current.name}.amazoncognito.com"
}

output "openid_config_url" {
  description = "OIDC discovery URL for Open WebUI"
  value       = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.ollama.id}/.well-known/openid-configuration"
}

output "signup_sns_topic_arn" {
  description = "SNS topic ARN for signup notifications"
  value       = aws_sns_topic.signup_notifications.arn
}
