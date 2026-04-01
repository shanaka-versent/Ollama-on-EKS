# API Key Portal Module — Self-Service API Key Management
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Provides a static portal (S3 + CloudFront) for users to generate, list,
# and revoke their own API Gateway keys. Uses the existing Cognito User Pool
# (ollama-webui) for authentication via a separate app client (SPA, no secret).
#
# Components:
#   - S3 bucket for portal static assets (OAC access)
#   - DynamoDB table for key metadata + audit trail
#   - Lambda function for key CRUD (Cognito-authenticated)
#   - Lambda function for nightly expiry checks (EventBridge)
#   - Cognito app client (public SPA, no secret)
#   - API Gateway resources on the existing REST API

data "aws_caller_identity" "current" {}

# ==============================================================================
# S3 BUCKET — Portal Static Assets
# ==============================================================================

resource "aws_s3_bucket" "portal" {
  bucket        = "${var.project_name}-api-key-portal-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "portal" {
  bucket                  = aws_s3_bucket.portal.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "portal" {
  bucket = aws_s3_bucket.portal.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "portal" {
  bucket = aws_s3_bucket.portal.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# OAC policy — only CloudFront can read from this bucket
resource "aws_s3_bucket_policy" "portal" {
  bucket = aws_s3_bucket.portal.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.portal.arn}/*"
      Condition = {
        StringLike = {
          "AWS:SourceArn" = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.portal]
}

# Upload static portal files
resource "aws_s3_object" "index_html" {
  bucket = aws_s3_bucket.portal.id
  key    = "portal/index.html"
  content = templatefile("${path.module}/static/index.html", {
    cloudfront_domain = var.cloudfront_domain
    api_base_url      = "https://${var.cloudfront_domain}"
  })
  content_type = "text/html"
  etag = md5(templatefile("${path.module}/static/index.html", {
    cloudfront_domain = var.cloudfront_domain
    api_base_url      = "https://${var.cloudfront_domain}"
  }))
}

# ==============================================================================
# S3 BUCKET — Login SPA (separate bucket for custom login page)
# ==============================================================================

resource "aws_s3_bucket" "login" {
  bucket        = "${var.project_name}-login-portal-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "login" {
  bucket                  = aws_s3_bucket.login.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "login" {
  bucket = aws_s3_bucket.login.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# OAC policy — only CloudFront can read from this bucket
resource "aws_s3_bucket_policy" "login" {
  bucket = aws_s3_bucket.login.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.login.arn}/*"
      Condition = {
        StringLike = {
          "AWS:SourceArn" = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.login]
}

resource "aws_cloudfront_origin_access_control" "login" {
  name                              = "${var.project_name}-login-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_object" "login_html" {
  bucket = aws_s3_bucket.login.id
  key    = "auth/login.html"
  content = templatefile("${path.module}/static/login.html", {
    signup_client_id = var.signup_client_id
    region           = var.region
  })
  content_type = "text/html"
  etag = md5(templatefile("${path.module}/static/login.html", {
    signup_client_id = var.signup_client_id
    region           = var.region
  }))
}

resource "aws_s3_object" "cleanup_html" {
  bucket        = aws_s3_bucket.login.id
  key           = "auth/cleanup.html"
  content       = file("${path.module}/static/cleanup.html")
  content_type  = "text/html"
  cache_control = "no-cache, no-store, must-revalidate"
  etag          = md5(file("${path.module}/static/cleanup.html"))
}

# ==============================================================================
# CLOUDFRONT OAC — Origin Access Control for S3
# ==============================================================================

resource "aws_cloudfront_origin_access_control" "portal" {
  name                              = "${var.project_name}-portal-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ==============================================================================
# DYNAMODB TABLE — API Key Metadata + Audit Trail
# ==============================================================================

resource "aws_dynamodb_table" "api_keys" {
  name         = "${var.project_name}-api-key-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "keyId"

  attribute {
    name = "keyId"
    type = "S"
  }

  attribute {
    name = "cognitoUserId"
    type = "S"
  }

  attribute {
    name = "createdDate"
    type = "S"
  }

  global_secondary_index {
    name            = "cognitoUserId-index"
    hash_key        = "cognitoUserId"
    range_key       = "createdDate"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = var.tags
}

# ==============================================================================
# LAMBDA — API Key Manager (CRUD)
# ==============================================================================

data "archive_file" "key_manager" {
  type        = "zip"
  source_file = "${path.module}/lambda/key_manager.py"
  output_path = "${path.module}/lambda/key_manager.zip"
}

resource "aws_lambda_function" "key_manager" {
  function_name    = "${var.project_name}-api-key-manager"
  handler          = "key_manager.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.key_manager.output_path
  source_code_hash = data.archive_file.key_manager.output_base64sha256
  role             = aws_iam_role.key_manager.arn

  environment {
    variables = {
      DYNAMO_TABLE      = aws_dynamodb_table.api_keys.name
      USAGE_PLAN_ID     = var.usage_plan_id
      PROJECT_NAME      = var.project_name
      MAX_KEYS_PER_USER = tostring(var.max_keys_per_user)
      KEY_EXPIRY_DAYS   = tostring(var.key_expiry_days)
    }
  }

  tags = var.tags
}

resource "aws_iam_role" "key_manager" {
  name = "${var.project_name}-api-key-manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "key_manager" {
  name = "api-key-management"
  role = aws_iam_role.key_manager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "apigateway:POST",
          "apigateway:GET",
          "apigateway:DELETE",
          "apigateway:PATCH",
          "apigateway:PUT",
        ]
        Resource = concat(
          [
            "arn:aws:apigateway:${var.region}::/apikeys",
            "arn:aws:apigateway:${var.region}::/apikeys/*",
            "arn:aws:apigateway:${var.region}::/tags/*",
          ],
          var.usage_plan_id != null && var.usage_plan_id != "" ? [
            "arn:aws:apigateway:${var.region}::/usageplans/${var.usage_plan_id}/keys",
            "arn:aws:apigateway:${var.region}::/usageplans/${var.usage_plan_id}/keys/*",
            ] : [
            "arn:aws:apigateway:${var.region}::/usageplans/*/keys",
            "arn:aws:apigateway:${var.region}::/usageplans/*/keys/*",
          ]
        )
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem",
        ]
        Resource = [
          aws_dynamodb_table.api_keys.arn,
          "${aws_dynamodb_table.api_keys.arn}/index/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

# Lambda permission for API Gateway to invoke
resource "aws_lambda_permission" "key_manager_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.key_manager.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.rest_api_execution_arn}/*/*"
}

# ==============================================================================
# LAMBDA — API Key Expiry Checker (nightly)
# ==============================================================================

data "archive_file" "expiry_checker" {
  type        = "zip"
  source_file = "${path.module}/lambda/expiry_checker.py"
  output_path = "${path.module}/lambda/expiry_checker.zip"
}

resource "aws_lambda_function" "expiry_checker" {
  function_name    = "${var.project_name}-api-key-expiry"
  handler          = "expiry_checker.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.expiry_checker.output_path
  source_code_hash = data.archive_file.expiry_checker.output_base64sha256
  role             = aws_iam_role.expiry_checker.arn

  environment {
    variables = {
      DYNAMO_TABLE = aws_dynamodb_table.api_keys.name
    }
  }

  tags = var.tags
}

resource "aws_iam_role" "expiry_checker" {
  name = "${var.project_name}-api-key-expiry"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "expiry_checker" {
  name = "expiry-check"
  role = aws_iam_role.expiry_checker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "apigateway:GET",
          "apigateway:PATCH",
        ]
        Resource = [
          "arn:aws:apigateway:${var.region}::/apikeys/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Scan",
          "dynamodb:UpdateItem",
        ]
        Resource = aws_dynamodb_table.api_keys.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

# ==============================================================================
# EVENTBRIDGE — Nightly Expiry Check
# ==============================================================================

resource "aws_cloudwatch_event_rule" "key_expiry" {
  name                = "${var.project_name}-api-key-expiry"
  description         = "Daily check for expired API keys"
  schedule_expression = "cron(0 2 * * ? *)" # 2 AM UTC daily
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "key_expiry" {
  rule      = aws_cloudwatch_event_rule.key_expiry.name
  target_id = "key-expiry-lambda"
  arn       = aws_lambda_function.expiry_checker.arn
}

resource "aws_lambda_permission" "eventbridge_expiry" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.expiry_checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.key_expiry.arn
}

# ==============================================================================
# API GATEWAY — Cognito Authorizer (validates id_token directly at API GW level)
# ==============================================================================
resource "aws_api_gateway_authorizer" "cognito" {
  name            = "${var.project_name}-cognito-authorizer"
  rest_api_id     = var.rest_api_id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [var.cognito_user_pool_arn]
  identity_source = "method.request.header.Authorization"
}

# ==============================================================================
# API GATEWAY — Portal API Resources (on existing REST API)
# ==============================================================================

# /portal
resource "aws_api_gateway_resource" "portal" {
  rest_api_id = var.rest_api_id
  parent_id   = var.rest_api_root_resource_id
  path_part   = "portal"
}

# /portal/api
resource "aws_api_gateway_resource" "portal_api" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal.id
  path_part   = "api"
}

# /portal/api/keys
resource "aws_api_gateway_resource" "portal_keys" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_api.id
  path_part   = "keys"
}

# /portal/api/keys/{keyId}
resource "aws_api_gateway_resource" "portal_key_by_id" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_keys.id
  path_part   = "{keyId}"
}

# --- GET /portal/api/keys (list user's keys) ---
# Auth: Cognito authorizer validates id_token at API Gateway level before Lambda is invoked.
resource "aws_api_gateway_method" "list_keys" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_keys.id
  http_method      = "GET"
  authorization    = "COGNITO_USER_POOLS"
  authorizer_id    = aws_api_gateway_authorizer.cognito.id
  api_key_required = false
}

resource "aws_api_gateway_integration" "list_keys" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.portal_keys.id
  http_method             = aws_api_gateway_method.list_keys.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.key_manager.invoke_arn
}

# --- POST /portal/api/keys (create key) ---
resource "aws_api_gateway_method" "create_key" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_keys.id
  http_method      = "POST"
  authorization    = "COGNITO_USER_POOLS"
  authorizer_id    = aws_api_gateway_authorizer.cognito.id
  api_key_required = false
}

resource "aws_api_gateway_integration" "create_key" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.portal_keys.id
  http_method             = aws_api_gateway_method.create_key.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.key_manager.invoke_arn
}

# --- PATCH /portal/api/keys/{keyId} (disable/enable) ---
resource "aws_api_gateway_method" "update_key" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_key_by_id.id
  http_method      = "PATCH"
  authorization    = "COGNITO_USER_POOLS"
  authorizer_id    = aws_api_gateway_authorizer.cognito.id
  api_key_required = false
}

resource "aws_api_gateway_integration" "update_key" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.portal_key_by_id.id
  http_method             = aws_api_gateway_method.update_key.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.key_manager.invoke_arn
}

# --- DELETE /portal/api/keys/{keyId} (revoke) ---
resource "aws_api_gateway_method" "delete_key" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_key_by_id.id
  http_method      = "DELETE"
  authorization    = "COGNITO_USER_POOLS"
  authorizer_id    = aws_api_gateway_authorizer.cognito.id
  api_key_required = false
}

resource "aws_api_gateway_integration" "delete_key" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.portal_key_by_id.id
  http_method             = aws_api_gateway_method.delete_key.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.key_manager.invoke_arn
}

# --- OPTIONS /portal/api/keys (CORS preflight) ---
resource "aws_api_gateway_method" "keys_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_keys.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "keys_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_keys.id
  http_method = aws_api_gateway_method.keys_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "keys_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_keys.id
  http_method = aws_api_gateway_method.keys_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "keys_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_keys.id
  http_method = aws_api_gateway_method.keys_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${var.cloudfront_domain}'"
  }

  depends_on = [aws_api_gateway_integration.keys_options]
}

# --- OPTIONS /portal/api/keys/{keyId} (CORS preflight) ---
resource "aws_api_gateway_method" "key_by_id_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_key_by_id.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "key_by_id_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_key_by_id.id
  http_method = aws_api_gateway_method.key_by_id_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "key_by_id_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_key_by_id.id
  http_method = aws_api_gateway_method.key_by_id_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "key_by_id_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_key_by_id.id
  http_method = aws_api_gateway_method.key_by_id_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'PATCH,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${var.cloudfront_domain}'"
  }

  depends_on = [aws_api_gateway_integration.key_by_id_options]
}

# ==============================================================================
# LAMBDA — Auth Proxy (bridges custom login form to Cognito + Open WebUI OAuth)
# ==============================================================================
# Proxies the full Cognito hosted UI login flow server-side so users see our
# custom login form instead of the Cognito hosted UI. Handles password auth
# and MFA (TOTP) in two steps.

data "archive_file" "auth_proxy" {
  type        = "zip"
  source_file = "${path.module}/lambda/auth_proxy.py"
  output_path = "${path.module}/lambda/auth_proxy.zip"
}

resource "aws_lambda_function" "auth_proxy" {
  function_name    = "${var.project_name}-auth-proxy"
  handler          = "auth_proxy.handler"
  runtime          = "python3.12"
  timeout          = 29
  memory_size      = 256
  filename         = data.archive_file.auth_proxy.output_path
  source_code_hash = data.archive_file.auth_proxy.output_base64sha256
  role             = aws_iam_role.auth_proxy.arn

  environment {
    variables = {
      CLOUDFRONT_DOMAIN     = var.cloudfront_domain
      USER_POOL_ID          = var.cognito_user_pool_id
      COGNITO_CLIENT_ID     = var.cognito_client_id
      COGNITO_CLIENT_SECRET = var.cognito_client_secret
      COGNITO_DOMAIN        = var.cognito_domain
    }
  }

  tags = var.tags
}

resource "aws_iam_role" "auth_proxy" {
  name = "${var.project_name}-auth-proxy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "auth_proxy" {
  name = "auth-proxy-permissions"
  role = aws_iam_role.auth_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:InitiateAuth",
          "cognito-idp:RespondToAuthChallenge",
          "cognito-idp:ForgotPassword",
          "cognito-idp:ConfirmForgotPassword",
          "cognito-idp:AssociateSoftwareToken",
          "cognito-idp:VerifySoftwareToken",
        ]
        Resource = "arn:aws:cognito-idp:${var.region}:${data.aws_caller_identity.current.account_id}:userpool/${var.cognito_user_pool_id}"
      },
    ]
  })
}

resource "aws_lambda_permission" "auth_proxy_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_proxy.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.rest_api_execution_arn}/*/*"
}

# ==============================================================================
# API GATEWAY — Auth Proxy Resources (/portal/api/auth/login, /portal/api/auth/mfa)
# ==============================================================================
# No Cognito authorizer — these are the login endpoints themselves.

# /portal/api/auth
resource "aws_api_gateway_resource" "portal_auth" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_api.id
  path_part   = "auth"
}

# /portal/api/auth/login
resource "aws_api_gateway_resource" "portal_auth_login" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_auth.id
  path_part   = "login"
}

# /portal/api/auth/mfa
resource "aws_api_gateway_resource" "portal_auth_mfa" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_auth.id
  path_part   = "mfa"
}

# --- POST /portal/api/auth/login ---
resource "aws_api_gateway_method" "auth_login" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_login.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_login" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.portal_auth_login.id
  http_method             = aws_api_gateway_method.auth_login.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.auth_proxy.invoke_arn
  timeout_milliseconds    = 29000 # Max for REST API; VPC Origin cold start can be slow
}

# --- POST /portal/api/auth/mfa ---
resource "aws_api_gateway_method" "auth_mfa" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_mfa.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_mfa" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.portal_auth_mfa.id
  http_method             = aws_api_gateway_method.auth_mfa.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.auth_proxy.invoke_arn
  timeout_milliseconds    = 29000 # Max for REST API; VPC Origin cold start can be slow
}

# --- OPTIONS /portal/api/auth/login (CORS preflight) ---
resource "aws_api_gateway_method" "auth_login_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_login.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_login_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_login.id
  http_method = aws_api_gateway_method.auth_login_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "auth_login_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_login.id
  http_method = aws_api_gateway_method.auth_login_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "auth_login_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_login.id
  http_method = aws_api_gateway_method.auth_login_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${var.cloudfront_domain}'"
  }

  depends_on = [aws_api_gateway_integration.auth_login_options]
}

# --- OPTIONS /portal/api/auth/mfa (CORS preflight) ---
resource "aws_api_gateway_method" "auth_mfa_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_mfa.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_mfa_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_mfa.id
  http_method = aws_api_gateway_method.auth_mfa_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "auth_mfa_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_mfa.id
  http_method = aws_api_gateway_method.auth_mfa_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "auth_mfa_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_mfa.id
  http_method = aws_api_gateway_method.auth_mfa_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${var.cloudfront_domain}'"
  }

  depends_on = [aws_api_gateway_integration.auth_mfa_options]
}

# ==============================================================================
# API GATEWAY — Additional Auth Endpoints (first-time setup + forgot password)
# ==============================================================================
# These endpoints handle flows that previously required Cognito hosted UI:
#   - change-password: NEW_PASSWORD_REQUIRED challenge (first-time login)
#   - setup-mfa: MFA_SETUP challenge — TOTP enrollment (first-time login)
#   - forgot-password: Initiates password reset (sends code via email)
#   - confirm-reset: Completes password reset (code + new password)

# /portal/api/auth/change-password
resource "aws_api_gateway_resource" "portal_auth_change_password" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_auth.id
  path_part   = "change-password"
}

# /portal/api/auth/setup-mfa
resource "aws_api_gateway_resource" "portal_auth_setup_mfa" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_auth.id
  path_part   = "setup-mfa"
}

# /portal/api/auth/forgot-password
resource "aws_api_gateway_resource" "portal_auth_forgot_password" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_auth.id
  path_part   = "forgot-password"
}

# /portal/api/auth/confirm-reset
resource "aws_api_gateway_resource" "portal_auth_confirm_reset" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_auth.id
  path_part   = "confirm-reset"
}

# --- POST /portal/api/auth/change-password ---
resource "aws_api_gateway_method" "auth_change_password" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_change_password.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_change_password" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.portal_auth_change_password.id
  http_method             = aws_api_gateway_method.auth_change_password.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.auth_proxy.invoke_arn
  timeout_milliseconds    = 29000
}

# --- POST /portal/api/auth/setup-mfa ---
resource "aws_api_gateway_method" "auth_setup_mfa" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_setup_mfa.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_setup_mfa" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.portal_auth_setup_mfa.id
  http_method             = aws_api_gateway_method.auth_setup_mfa.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.auth_proxy.invoke_arn
  timeout_milliseconds    = 29000
}

# --- POST /portal/api/auth/forgot-password ---
resource "aws_api_gateway_method" "auth_forgot_password" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_forgot_password.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_forgot_password" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.portal_auth_forgot_password.id
  http_method             = aws_api_gateway_method.auth_forgot_password.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.auth_proxy.invoke_arn
  timeout_milliseconds    = 29000
}

# --- POST /portal/api/auth/confirm-reset ---
resource "aws_api_gateway_method" "auth_confirm_reset" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_confirm_reset.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_confirm_reset" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.portal_auth_confirm_reset.id
  http_method             = aws_api_gateway_method.auth_confirm_reset.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.auth_proxy.invoke_arn
  timeout_milliseconds    = 29000
}

# --- OPTIONS /portal/api/auth/change-password (CORS preflight) ---
resource "aws_api_gateway_method" "auth_change_password_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_change_password.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_change_password_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_change_password.id
  http_method = aws_api_gateway_method.auth_change_password_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "auth_change_password_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_change_password.id
  http_method = aws_api_gateway_method.auth_change_password_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "auth_change_password_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_change_password.id
  http_method = aws_api_gateway_method.auth_change_password_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${var.cloudfront_domain}'"
  }

  depends_on = [aws_api_gateway_integration.auth_change_password_options]
}

# --- OPTIONS /portal/api/auth/setup-mfa (CORS preflight) ---
resource "aws_api_gateway_method" "auth_setup_mfa_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_setup_mfa.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_setup_mfa_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_setup_mfa.id
  http_method = aws_api_gateway_method.auth_setup_mfa_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "auth_setup_mfa_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_setup_mfa.id
  http_method = aws_api_gateway_method.auth_setup_mfa_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "auth_setup_mfa_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_setup_mfa.id
  http_method = aws_api_gateway_method.auth_setup_mfa_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${var.cloudfront_domain}'"
  }

  depends_on = [aws_api_gateway_integration.auth_setup_mfa_options]
}

# --- OPTIONS /portal/api/auth/forgot-password (CORS preflight) ---
resource "aws_api_gateway_method" "auth_forgot_password_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_forgot_password.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_forgot_password_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_forgot_password.id
  http_method = aws_api_gateway_method.auth_forgot_password_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "auth_forgot_password_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_forgot_password.id
  http_method = aws_api_gateway_method.auth_forgot_password_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "auth_forgot_password_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_forgot_password.id
  http_method = aws_api_gateway_method.auth_forgot_password_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${var.cloudfront_domain}'"
  }

  depends_on = [aws_api_gateway_integration.auth_forgot_password_options]
}

# --- OPTIONS /portal/api/auth/confirm-reset (CORS preflight) ---
resource "aws_api_gateway_method" "auth_confirm_reset_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.portal_auth_confirm_reset.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "auth_confirm_reset_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_confirm_reset.id
  http_method = aws_api_gateway_method.auth_confirm_reset_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "auth_confirm_reset_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_confirm_reset.id
  http_method = aws_api_gateway_method.auth_confirm_reset_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "auth_confirm_reset_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.portal_auth_confirm_reset.id
  http_method = aws_api_gateway_method.auth_confirm_reset_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${var.cloudfront_domain}'"
  }

  depends_on = [aws_api_gateway_integration.auth_confirm_reset_options]
}

# ==============================================================================
# API GATEWAY — Redeployment (updates existing prod stage)
# ==============================================================================

resource "aws_api_gateway_deployment" "portal" {
  rest_api_id = var.rest_api_id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_method.list_keys,
      aws_api_gateway_method.create_key,
      aws_api_gateway_method.update_key,
      aws_api_gateway_method.delete_key,
      aws_api_gateway_method.auth_login,
      aws_api_gateway_method.auth_mfa,
      aws_api_gateway_method.auth_change_password,
      aws_api_gateway_method.auth_setup_mfa,
      aws_api_gateway_method.auth_forgot_password,
      aws_api_gateway_method.auth_confirm_reset,
      aws_api_gateway_authorizer.cognito,
      var.api_deployment_trigger,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.list_keys,
    aws_api_gateway_integration.create_key,
    aws_api_gateway_integration.update_key,
    aws_api_gateway_integration.delete_key,
    aws_api_gateway_integration.keys_options,
    aws_api_gateway_integration.key_by_id_options,
    aws_api_gateway_integration_response.keys_options,
    aws_api_gateway_integration_response.key_by_id_options,
    aws_api_gateway_integration.auth_login,
    aws_api_gateway_integration.auth_mfa,
    aws_api_gateway_integration.auth_login_options,
    aws_api_gateway_integration.auth_mfa_options,
    aws_api_gateway_integration_response.auth_login_options,
    aws_api_gateway_integration_response.auth_mfa_options,
    aws_api_gateway_integration.auth_change_password,
    aws_api_gateway_integration.auth_setup_mfa,
    aws_api_gateway_integration.auth_forgot_password,
    aws_api_gateway_integration.auth_confirm_reset,
    aws_api_gateway_integration.auth_change_password_options,
    aws_api_gateway_integration.auth_setup_mfa_options,
    aws_api_gateway_integration.auth_forgot_password_options,
    aws_api_gateway_integration.auth_confirm_reset_options,
    aws_api_gateway_integration_response.auth_change_password_options,
    aws_api_gateway_integration_response.auth_setup_mfa_options,
    aws_api_gateway_integration_response.auth_forgot_password_options,
    aws_api_gateway_integration_response.auth_confirm_reset_options,
    # GPU controller routes
    aws_api_gateway_integration.gpu_status,
    aws_api_gateway_integration.gpu_start,
    aws_api_gateway_integration.gpu_stop,
    aws_api_gateway_integration.gpu_status_options,
    aws_api_gateway_integration.gpu_start_options,
    aws_api_gateway_integration.gpu_stop_options,
    aws_api_gateway_integration_response.gpu_status_options,
    aws_api_gateway_integration_response.gpu_start_options,
    aws_api_gateway_integration_response.gpu_stop_options,
  ]
}

# Point the existing prod stage to this new deployment (create if first apply)
resource "null_resource" "update_stage" {
  triggers = {
    deployment_id = aws_api_gateway_deployment.portal.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Try to update existing stage first; create it if it doesn't exist
      aws apigateway update-stage \
        --rest-api-id ${var.rest_api_id} \
        --stage-name prod \
        --patch-operations op=replace,path=/deploymentId,value=${aws_api_gateway_deployment.portal.id} \
        --region ${var.region} 2>/dev/null || \
      aws apigateway create-stage \
        --rest-api-id ${var.rest_api_id} \
        --stage-name prod \
        --deployment-id ${aws_api_gateway_deployment.portal.id} \
        --region ${var.region}
    EOT
  }
}

# ==============================================================================
# LAMBDA — GPU Controller (self-service GPU start/stop/status)
# ==============================================================================
# Allows users to start/stop the Ollama GPU node from the WebUI without
# requiring kubectl access. Uses K8s API via EKS bearer token (STS presigned).

data "archive_file" "gpu_controller" {
  type        = "zip"
  source_file = "${path.module}/lambda/gpu_controller.py"
  output_path = "${path.module}/lambda/gpu_controller.zip"
}

resource "aws_lambda_function" "gpu_controller" {
  function_name    = "${var.project_name}-gpu-controller"
  handler          = "gpu_controller.handler"
  runtime          = "python3.12"
  timeout          = 15
  memory_size      = 128
  filename         = data.archive_file.gpu_controller.output_path
  source_code_hash = data.archive_file.gpu_controller.output_base64sha256
  role             = aws_iam_role.gpu_controller.arn

  environment {
    variables = {
      EKS_CLUSTER_NAME   = var.eks_cluster_name
      OLLAMA_NAMESPACE   = "ollama"
      OLLAMA_DEPLOYMENT  = "ollama"
      KEDA_SCALED_OBJECT = "ollama-autoscaler"
      CLOUDFRONT_DOMAIN  = var.cloudfront_domain
    }
  }

  tags = var.tags
}

resource "aws_iam_role" "gpu_controller" {
  name = "${var.project_name}-gpu-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "gpu_controller" {
  name = "gpu-controller-permissions"
  role = aws_iam_role.gpu_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.eks_cluster_name}"
      },
    ]
  })
}

resource "aws_lambda_permission" "gpu_controller_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.gpu_controller.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.rest_api_execution_arn}/*/*"
}

# ==============================================================================
# EVENTBRIDGE — KEDA Safety Check (auto-unpause after 30 min grace)
# ==============================================================================

resource "aws_cloudwatch_event_rule" "keda_safety_check" {
  name                = "ollama-keda-safety-check"
  description         = "Auto-unpause KEDA after 30 min grace — prevents forgotten GPU from running indefinitely"
  schedule_expression = "rate(5 minutes)"
  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_cloudwatch_event_target" "keda_safety_check" {
  rule = aws_cloudwatch_event_rule.keda_safety_check.name
  arn  = aws_lambda_function.gpu_controller.arn
}

resource "aws_lambda_permission" "gpu_controller_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.gpu_controller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.keda_safety_check.arn
}

# ==============================================================================
# S3 — GPU Control Page (served via login S3 bucket)
# ==============================================================================

resource "aws_s3_object" "gpu_html" {
  bucket       = aws_s3_bucket.portal.id
  key          = "portal/gpu.html"
  source       = "${path.module}/static/gpu.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/static/gpu.html")
}

# ==============================================================================
# API GATEWAY — GPU Controller Resources (/portal/api/gpu/*)
# ==============================================================================

# /portal/api/gpu
resource "aws_api_gateway_resource" "portal_gpu" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_api.id
  path_part   = "gpu"
}

# /portal/api/gpu/status
resource "aws_api_gateway_resource" "gpu_status" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_gpu.id
  path_part   = "status"
}

# /portal/api/gpu/start
resource "aws_api_gateway_resource" "gpu_start" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_gpu.id
  path_part   = "start"
}

# /portal/api/gpu/stop
resource "aws_api_gateway_resource" "gpu_stop" {
  rest_api_id = var.rest_api_id
  parent_id   = aws_api_gateway_resource.portal_gpu.id
  path_part   = "stop"
}

# --- GET /portal/api/gpu/status ---
resource "aws_api_gateway_method" "gpu_status" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.gpu_status.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "gpu_status" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.gpu_status.id
  http_method             = aws_api_gateway_method.gpu_status.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.gpu_controller.invoke_arn
}

# --- POST /portal/api/gpu/start ---
resource "aws_api_gateway_method" "gpu_start" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.gpu_start.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "gpu_start" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.gpu_start.id
  http_method             = aws_api_gateway_method.gpu_start.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.gpu_controller.invoke_arn
}

# --- POST /portal/api/gpu/stop ---
resource "aws_api_gateway_method" "gpu_stop" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.gpu_stop.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "gpu_stop" {
  rest_api_id             = var.rest_api_id
  resource_id             = aws_api_gateway_resource.gpu_stop.id
  http_method             = aws_api_gateway_method.gpu_stop.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.gpu_controller.invoke_arn
}

# --- OPTIONS (CORS preflight) for all GPU endpoints ---
resource "aws_api_gateway_method" "gpu_status_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.gpu_status.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "gpu_status_options" {
  rest_api_id       = var.rest_api_id
  resource_id       = aws_api_gateway_resource.gpu_status.id
  http_method       = aws_api_gateway_method.gpu_status_options.http_method
  type              = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "gpu_status_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.gpu_status.id
  http_method = aws_api_gateway_method.gpu_status_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "gpu_status_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.gpu_status.id
  http_method = aws_api_gateway_method.gpu_status_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.gpu_status_options]
}

resource "aws_api_gateway_method" "gpu_start_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.gpu_start.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "gpu_start_options" {
  rest_api_id       = var.rest_api_id
  resource_id       = aws_api_gateway_resource.gpu_start.id
  http_method       = aws_api_gateway_method.gpu_start_options.http_method
  type              = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "gpu_start_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.gpu_start.id
  http_method = aws_api_gateway_method.gpu_start_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "gpu_start_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.gpu_start.id
  http_method = aws_api_gateway_method.gpu_start_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.gpu_start_options]
}

resource "aws_api_gateway_method" "gpu_stop_options" {
  rest_api_id      = var.rest_api_id
  resource_id      = aws_api_gateway_resource.gpu_stop.id
  http_method      = "OPTIONS"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "gpu_stop_options" {
  rest_api_id       = var.rest_api_id
  resource_id       = aws_api_gateway_resource.gpu_stop.id
  http_method       = aws_api_gateway_method.gpu_stop_options.http_method
  type              = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "gpu_stop_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.gpu_stop.id
  http_method = aws_api_gateway_method.gpu_stop_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "gpu_stop_options" {
  rest_api_id = var.rest_api_id
  resource_id = aws_api_gateway_resource.gpu_stop.id
  http_method = aws_api_gateway_method.gpu_stop_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.gpu_stop_options]
}
