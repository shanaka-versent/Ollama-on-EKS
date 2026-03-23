# CDN + WAF Module — CloudFront Distribution with WAFv2 Web ACL
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# CloudFront fronts the API Gateway with WAF protection:
#   1. Rate Limiting — 100 requests per 5-minute window per IP
#   2. IP Allowlist — Only corporate CIDR ranges
#   3. Geo-Blocking — AU + US only (configurable)
#   4. Bot Control — AWS managed rule group (optional)
#   5. SQL/XSS — AWSManagedRulesCommonRuleSet
#
# NOTE: WAF for CloudFront must be created in us-east-1.
#       This module uses a separate provider alias for that.

# --- Locals ---
locals {
  # Skip IP allowlist rule when "0.0.0.0/0" is set (means "allow all")
  ip_allowlist_enabled    = !contains(var.allowed_ips, "0.0.0.0/0")
  origin_lockdown_enabled = var.enable_origin_lockdown
  webui_enabled           = var.nlb_dns_name != "" && var.nlb_arn != ""
  portal_enabled          = var.portal_s3_bucket_regional_domain != ""
  login_enabled           = var.login_s3_bucket_regional_domain != ""
}

# --- CloudFront Function: Auth Redirect ---
# Redirects unauthenticated users directly to the OIDC login endpoint,
# skipping the Open WebUI landing page. Logged-in users (with session cookie)
# pass through to the dashboard. Excludes OAuth callback, static assets,
# and API paths from redirect.
resource "aws_cloudfront_function" "auth_redirect" {
  count = local.webui_enabled ? 1 : 0

  name    = "${var.project_name}-auth-redirect"
  runtime = "cloudfront-js-2.0"
  publish = true

  code = <<-JS
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      var cookies = request.cookies || {};

      // Paths that must NOT be redirected
      if (uri.startsWith('/oauth/') ||
          uri.startsWith('/_app/') ||
          uri.startsWith('/static/') ||
          uri.startsWith('/api/') ||
          uri.startsWith('/v1/') ||
          uri.startsWith('/portal/') ||
          uri.startsWith('/auth/') ||
          uri === '/favicon.ico' ||
          uri === '/favicon.png' ||
          uri === '/health' ||
          uri === '/manifest.json') {
        return request;
      }

      // If user has a valid session cookie, let them through to Open WebUI
      if (cookies['token']) {
        return request;
      }

      // No session — redirect to custom login page (hosted on separate S3 bucket)
      return {
        statusCode: 302,
        statusDescription: 'Found',
        headers: {
          location: { value: '/auth/login.html' },
          'cache-control': { value: 'no-cache, no-store, must-revalidate' }
        }
      };
    }
  JS
}

# --- CloudFront VPC Origin (private connectivity to internal NLB) ---
# This is the key pattern: CloudFront connects privately to the internal NLB
# via VPC Origins, no internet-facing NLB needed. This is why we use the
# Gateway API pattern — the internal NLB stays fully private.
resource "aws_cloudfront_vpc_origin" "nlb" {
  count = local.webui_enabled ? 1 : 0

  vpc_origin_endpoint_config {
    name                 = "${var.project_name}-nlb-origin"
    arn                  = var.nlb_arn
    http_port            = 80
    https_port           = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  tags = var.tags
}

# --- WAFv2 Web ACL (must be in us-east-1 for CloudFront) ---
resource "aws_wafv2_web_acl" "ollama" {
  provider = aws.us_east_1

  name        = "${var.project_name}-waf"
  description = "WAF for Ollama LLM API - rate limit, IP allowlist, geo-block"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Rule 1: Rate Limiting
  rule {
    name     = "rate-limit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: IP Allowlist (skipped when allowed_ips includes 0.0.0.0/0)
  dynamic "rule" {
    for_each = local.ip_allowlist_enabled ? [1] : []
    content {
      name     = "ip-allowlist"
      priority = 2

      action {
        block {}
      }

      statement {
        not_statement {
          statement {
            ip_set_reference_statement {
              arn = aws_wafv2_ip_set.allowed_ips[0].arn
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.project_name}-ip-allowlist"
        sampled_requests_enabled   = true
      }
    }
  }

  # Rule 3: Geo-Blocking
  rule {
    name     = "geo-block"
    priority = 3

    action {
      block {}
    }

    statement {
      not_statement {
        statement {
          geo_match_statement {
            country_codes = var.geo_countries
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-geo-block"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: AWS Managed Rules — Common Rule Set (SQL/XSS)
  rule {
    name     = "aws-common-rules"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # Rule 5: Bot Control (optional)
  dynamic "rule" {
    for_each = var.enable_bot_control ? [1] : []
    content {
      name     = "bot-control"
      priority = 5

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = "AWSManagedRulesBotControlRuleSet"
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.project_name}-bot-control"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# --- IP Set for Allowlist (only created when specific CIDRs are provided) ---
resource "aws_wafv2_ip_set" "allowed_ips" {
  count    = local.ip_allowlist_enabled ? 1 : 0
  provider = aws.us_east_1

  name               = "${var.project_name}-allowed-ips"
  description        = "Corporate IP ranges allowed to access Ollama API"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = var.allowed_ips

  tags = var.tags
}

# --- CloudFront Distribution ---
resource "aws_cloudfront_distribution" "ollama" {
  enabled         = true
  comment         = "Ollama LLM API — fronts API Gateway with WAF"
  web_acl_id      = aws_wafv2_web_acl.ollama.arn
  price_class     = "PriceClass_200"
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    # REST API endpoint: https://{id}.execute-api.{region}.amazonaws.com/prod
    # Extract domain only; stage path (/prod) goes in origin_path
    domain_name = replace(replace(var.api_gateway_endpoint, "https://", ""), "/prod", "")
    origin_id   = "api-gateway"
    origin_path = "/prod"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Origin lockdown: CloudFront overrides the Referer header with a shared secret.
    # API Gateway resource policy checks aws:Referer to block direct access.
    # This is the AWS-recommended zero-cost pattern for origin lockdown.
    dynamic "custom_header" {
      for_each = local.origin_lockdown_enabled ? [1] : []
      content {
        name  = "Referer"
        value = var.origin_verify_secret
      }
    }
  }

  # NLB origin via VPC Origins (private connectivity to internal NLB)
  # CloudFront connects privately — no internet-facing NLB needed
  # Custom header: CloudFront uses CloudFront-Forwarded-Proto (not X-Forwarded-Proto),
  # but uvicorn/Open WebUI reads X-Forwarded-Proto for scheme detection (OAuth redirect_uri).
  dynamic "origin" {
    for_each = local.webui_enabled ? [1] : []
    content {
      domain_name = var.nlb_dns_name
      origin_id   = "nlb-webui"

      custom_header {
        name  = "X-Forwarded-Proto"
        value = "https"
      }

      vpc_origin_config {
        vpc_origin_id = aws_cloudfront_vpc_origin.nlb[0].id
      }
    }
  }

  # S3 origin for API Key Portal (OAC access)
  dynamic "origin" {
    for_each = local.portal_enabled ? [1] : []
    content {
      domain_name              = var.portal_s3_bucket_regional_domain
      origin_id                = "portal-s3"
      origin_access_control_id = var.portal_oac_id
    }
  }

  # S3 origin for Login SPA (separate bucket, OAC access)
  dynamic "origin" {
    for_each = local.login_enabled ? [1] : []
    content {
      domain_name              = var.login_s3_bucket_regional_domain
      origin_id                = "login-s3"
      origin_access_control_id = var.login_oac_id
    }
  }

  # Default behavior: Open WebUI (when enabled), otherwise API Gateway
  # VPC Origins require AllViewerExceptHostHeader — forwarding the viewer Host
  # header breaks the private NLB connection. OPENID_REDIRECT_URI env var on
  # Open WebUI handles OAuth redirect_uri separately.
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.webui_enabled ? "nlb-webui" : "api-gateway"

    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader

    viewer_protocol_policy = "https-only"
    compress               = true

    # Auto-redirect unauthenticated users to Cognito login (skip landing page)
    dynamic "function_association" {
      for_each = local.webui_enabled ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.auth_redirect[0].arn
      }
    }
  }

  # Open WebUI static assets → NLB (cached at CloudFront edge)
  # /_app/ contains SvelteKit JS/CSS bundles, fonts, and images.
  # Caching these at the edge eliminates the CloudFront → NLB → Istio → Pod
  # round-trip for every static file, reducing page load from ~10s to <1s.
  dynamic "ordered_cache_behavior" {
    for_each = local.webui_enabled ? ["/_app/*", "/static/*"] : []
    content {
      path_pattern     = ordered_cache_behavior.value
      allowed_methods  = ["GET", "HEAD", "OPTIONS"]
      cached_methods   = ["GET", "HEAD"]
      target_origin_id = "nlb-webui"

      cache_policy_id          = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader

      viewer_protocol_policy = "https-only"
      compress               = true
    }
  }

  # Portal API → API Gateway (Cognito-authenticated Lambda)
  dynamic "ordered_cache_behavior" {
    for_each = local.portal_enabled ? [1] : []
    content {
      path_pattern     = "/portal/api/*"
      allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods   = ["GET", "HEAD"]
      target_origin_id = "api-gateway"

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader

      viewer_protocol_policy = "https-only"
      compress               = true
    }
  }

  # Portal static assets → S3 (OAC)
  dynamic "ordered_cache_behavior" {
    for_each = local.portal_enabled ? [1] : []
    content {
      path_pattern     = "/portal/*"
      allowed_methods  = ["GET", "HEAD", "OPTIONS"]
      cached_methods   = ["GET", "HEAD"]
      target_origin_id = "portal-s3"

      cache_policy_id          = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
      origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # CORS-S3Origin

      viewer_protocol_policy = "https-only"
      compress               = true
    }
  }

  # Login SPA → separate S3 bucket (OAC)
  dynamic "ordered_cache_behavior" {
    for_each = local.login_enabled ? [1] : []
    content {
      path_pattern     = "/auth/*"
      allowed_methods  = ["GET", "HEAD", "OPTIONS"]
      cached_methods   = ["GET", "HEAD"]
      target_origin_id = "login-s3"

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled (login page should never be cached)
      origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # CORS-S3Origin

      viewer_protocol_policy = "https-only"
      compress               = true
    }
  }

  # API paths → API Gateway (with API key auth)
  dynamic "ordered_cache_behavior" {
    for_each = local.webui_enabled ? ["/v1/*", "/api/tags"] : []
    content {
      path_pattern     = ordered_cache_behavior.value
      allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods   = ["GET", "HEAD"]
      target_origin_id = "api-gateway"

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader

      viewer_protocol_policy = "https-only"
      compress               = true
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = var.geo_countries
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = var.tags
}
