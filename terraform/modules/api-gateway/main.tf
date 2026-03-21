# API Gateway Module — REST API with VPC Link, Native API Key Management
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# REST API (v1) with native usage plans and API keys — managed via AWS Console.
# Proxies POST /v1/chat/completions and GET /api/tags to internal NLB via VPC Link.
# API key authentication via x-api-key header, same pattern as the Claude API.

# ==============================================================================
# REST API
# ==============================================================================

resource "aws_api_gateway_rest_api" "ollama" {
  name        = "${var.project_name}-api"
  description = "Ollama LLM API — REST API with native API key management"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags
}

# ==============================================================================
# VPC LINK to Internal NLB
# ==============================================================================

resource "aws_api_gateway_vpc_link" "ollama" {
  name        = "${var.project_name}-vpc-link"
  target_arns = [var.nlb_arn]

  tags = var.tags
}

# ==============================================================================
# RESOURCES + METHODS
# ==============================================================================

# --- /v1 ---
resource "aws_api_gateway_resource" "v1" {
  rest_api_id = aws_api_gateway_rest_api.ollama.id
  parent_id   = aws_api_gateway_rest_api.ollama.root_resource_id
  path_part   = "v1"
}

# --- /v1/chat ---
resource "aws_api_gateway_resource" "chat" {
  rest_api_id = aws_api_gateway_rest_api.ollama.id
  parent_id   = aws_api_gateway_resource.v1.id
  path_part   = "chat"
}

# --- /v1/chat/completions ---
resource "aws_api_gateway_resource" "completions" {
  rest_api_id = aws_api_gateway_rest_api.ollama.id
  parent_id   = aws_api_gateway_resource.chat.id
  path_part   = "completions"
}

# --- POST /v1/chat/completions ---
resource "aws_api_gateway_method" "chat_completions" {
  rest_api_id      = aws_api_gateway_rest_api.ollama.id
  resource_id      = aws_api_gateway_resource.completions.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = var.api_key_required
}

resource "aws_api_gateway_integration" "chat_completions" {
  rest_api_id = aws_api_gateway_rest_api.ollama.id
  resource_id = aws_api_gateway_resource.completions.id
  http_method = aws_api_gateway_method.chat_completions.http_method

  type                    = "HTTP_PROXY"
  integration_http_method = "POST"
  uri                     = "http://${var.nlb_dns_name}:11434/v1/chat/completions"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.ollama.id

  timeout_milliseconds = 120000 # 2 min — LLM inference can be slow
}

# --- /api ---
resource "aws_api_gateway_resource" "api" {
  rest_api_id = aws_api_gateway_rest_api.ollama.id
  parent_id   = aws_api_gateway_rest_api.ollama.root_resource_id
  path_part   = "api"
}

# --- /api/tags ---
resource "aws_api_gateway_resource" "tags" {
  rest_api_id = aws_api_gateway_rest_api.ollama.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "tags"
}

# --- GET /api/tags ---
resource "aws_api_gateway_method" "api_tags" {
  rest_api_id      = aws_api_gateway_rest_api.ollama.id
  resource_id      = aws_api_gateway_resource.tags.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = var.api_key_required
}

resource "aws_api_gateway_integration" "api_tags" {
  rest_api_id = aws_api_gateway_rest_api.ollama.id
  resource_id = aws_api_gateway_resource.tags.id
  http_method = aws_api_gateway_method.api_tags.http_method

  type                    = "HTTP_PROXY"
  integration_http_method = "GET"
  uri                     = "http://${var.nlb_dns_name}:11434/api/tags"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.ollama.id

  timeout_milliseconds = 10000
}

# ==============================================================================
# DEPLOYMENT + STAGE
# ==============================================================================

resource "aws_api_gateway_deployment" "ollama" {
  rest_api_id = aws_api_gateway_rest_api.ollama.id

  # Redeploy when routes or integrations change
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_method.chat_completions,
      aws_api_gateway_integration.chat_completions,
      aws_api_gateway_method.api_tags,
      aws_api_gateway_integration.api_tags,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.chat_completions,
    aws_api_gateway_integration.api_tags,
  ]
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.ollama.id
  deployment_id = aws_api_gateway_deployment.ollama.id
  stage_name    = "prod"

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      caller             = "$context.identity.caller"
      apiKey             = "$context.identity.apiKeyId"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      resourcePath       = "$context.resourcePath"
      status             = "$context.status"
      protocol           = "$context.protocol"
      responseLength     = "$context.responseLength"
      integrationLatency = "$context.integrationLatency"
    })
  }

  tags = var.tags
}

# --- Method throttling ---
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.ollama.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.throttle_rate
    throttling_burst_limit = var.throttle_burst
    metrics_enabled        = true
    logging_level          = "INFO"
  }
}

# ==============================================================================
# API KEY + USAGE PLAN — Console-Managed
# ==============================================================================
# Creates an initial API key and usage plan. Additional keys can be created,
# rotated, disabled, and monitored directly from the AWS Console:
#   Console → API Gateway → Usage Plans → ollama-standard → API Keys
#
# Per-key features available in Console:
#   - Create/delete keys
#   - Enable/disable keys (instant revocation)
#   - Per-key usage metrics
#   - Per-plan rate limits and quotas
#   - Export usage data

resource "aws_api_gateway_usage_plan" "standard" {
  count = var.api_key_required ? 1 : 0

  name        = "${var.project_name}-standard"
  description = "Standard usage plan for Ollama LLM API access"

  api_stages {
    api_id = aws_api_gateway_rest_api.ollama.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  throttle_settings {
    rate_limit  = var.throttle_rate
    burst_limit = var.throttle_burst
  }

  # Optional: daily/monthly quota (uncomment to enforce)
  # quota_settings {
  #   limit  = 10000
  #   period = "DAY"
  # }

  tags = var.tags
}

# Initial API key — additional keys created via Console
resource "aws_api_gateway_api_key" "initial" {
  count = var.api_key_required ? 1 : 0

  name        = "${var.project_name}-initial-key"
  description = "Initial API key (create additional keys via AWS Console)"
  enabled     = true

  tags = var.tags
}

# Associate key with usage plan
resource "aws_api_gateway_usage_plan_key" "initial" {
  count = var.api_key_required ? 1 : 0

  key_id        = aws_api_gateway_api_key.initial[0].id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.standard[0].id
}

# ==============================================================================
# CLOUDWATCH LOGS
# ==============================================================================

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.project_name}-api"
  retention_in_days = 30

  tags = var.tags
}

# IAM role for CloudWatch logging
resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch.arn
}

resource "aws_iam_role" "api_gateway_cloudwatch" {
  name = "${var.project_name}-apigw-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch" {
  role       = aws_iam_role.api_gateway_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}
