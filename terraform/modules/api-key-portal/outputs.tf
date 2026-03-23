# API Key Portal Module — Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "portal_url" {
  description = "URL for the API Key Portal"
  value       = "https://${var.cloudfront_domain}/portal/"
}

output "s3_bucket_regional_domain" {
  description = "S3 bucket regional domain name (for CloudFront origin)"
  value       = aws_s3_bucket.portal.bucket_regional_domain_name
}

output "oac_id" {
  description = "CloudFront Origin Access Control ID (for S3 origin)"
  value       = aws_cloudfront_origin_access_control.portal.id
}

output "dynamo_table_name" {
  description = "DynamoDB table name for API key metadata"
  value       = aws_dynamodb_table.api_keys.name
}

output "portal_client_id" {
  description = "Cognito app client ID for the portal SPA"
  value       = aws_cognito_user_pool_client.portal.id
}

output "lambda_manager_invoke_arn" {
  description = "Lambda invoke ARN for the key management function"
  value       = aws_lambda_function.key_manager.invoke_arn
}

output "lambda_manager_function_name" {
  description = "Lambda function name for the key manager"
  value       = aws_lambda_function.key_manager.function_name
}

output "login_s3_bucket_regional_domain" {
  description = "Login SPA S3 bucket regional domain name (for CloudFront origin)"
  value       = aws_s3_bucket.login.bucket_regional_domain_name
}

output "login_oac_id" {
  description = "CloudFront Origin Access Control ID for login SPA S3 origin"
  value       = aws_cloudfront_origin_access_control.login.id
}
