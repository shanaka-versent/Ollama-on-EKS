# CDN + WAF Module — Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "cloudfront_domain" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.ollama.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.ollama.id
}

output "waf_arn" {
  description = "WAFv2 Web ACL ARN"
  value       = aws_wafv2_web_acl.ollama.arn
}

output "waf_id" {
  description = "WAFv2 Web ACL ID"
  value       = aws_wafv2_web_acl.ollama.id
}
