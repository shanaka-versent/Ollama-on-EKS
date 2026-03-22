# Grafana Cognito Module — Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.grafana.id
}

output "client_id" {
  description = "OAuth client ID for Grafana"
  value       = aws_cognito_user_pool_client.grafana.id
}

output "client_secret" {
  description = "OAuth client secret for Grafana"
  value       = aws_cognito_user_pool_client.grafana.client_secret
  sensitive   = true
}

output "cognito_domain" {
  description = "Cognito hosted UI domain (full URL)"
  value       = "https://${aws_cognito_user_pool_domain.grafana.domain}.auth.${data.aws_region.current.name}.amazoncognito.com"
}

output "auth_url" {
  description = "OAuth authorize endpoint"
  value       = "https://${aws_cognito_user_pool_domain.grafana.domain}.auth.${data.aws_region.current.name}.amazoncognito.com/oauth2/authorize"
}

output "token_url" {
  description = "OAuth token endpoint"
  value       = "https://${aws_cognito_user_pool_domain.grafana.domain}.auth.${data.aws_region.current.name}.amazoncognito.com/oauth2/token"
}

output "userinfo_url" {
  description = "OAuth userinfo endpoint"
  value       = "https://${aws_cognito_user_pool_domain.grafana.domain}.auth.${data.aws_region.current.name}.amazoncognito.com/oauth2/userInfo"
}
