# Cognito Module — User Pool with MFA + OAuth for Open WebUI
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Provides centralized authentication for Open WebUI:
#   - Cognito User Pool with required TOTP MFA
#   - Groups: admin, user (mapped to Open WebUI roles)
#   - OAuth 2.0 / OIDC app client for Open WebUI
#   - Cognito hosted UI domain
#   - Pre Sign-up Lambda for admin notification via SNS
#   - Initial admin user (receives temp password via email)
#
# User flow:
#   1. User opens CloudFront URL → redirected to Cognito hosted UI
#   2. Signs up (or logs in) with email + password
#   3. First login forces MFA setup (authenticator app QR code)
#   4. Admin gets SNS notification of new signup
#   5. Admin assigns user to group in Cognito Console
#   6. User can now access Open WebUI (role mapped from Cognito group)

# ==============================================================================
# USER POOL
# ==============================================================================

resource "aws_cognito_user_pool" "ollama" {
  name = "${var.project_name}-webui"

  # Username is email
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Password policy
  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # MFA — required for all users (TOTP via authenticator app)
  mfa_configuration = "ON"
  software_token_mfa_configuration {
    enabled = true
  }

  # Email configuration (Cognito default sender)
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # Custom invite email — identifies this as the Open WebUI login
  admin_create_user_config {
    invite_message_template {
      email_subject = "Ollama Open WebUI — Your Login Credentials"
      email_message = "You have been invited to Ollama Open WebUI (Chat Interface).\n\nUsername: {username}\nTemporary password: {####}\n\nLogin at: https://${var.cloudfront_domain}/\n\nYou will be asked to set a new password and configure MFA on first login."
      sms_message   = "Ollama WebUI — Username: {username}, Password: {####}"
    }
  }

  # Schema: email is required
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 5
      max_length = 128
    }
  }

  # Account recovery via email
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Pre sign-up Lambda trigger — notifies admin of new signups
  lambda_config {
    pre_sign_up = aws_lambda_function.pre_signup.arn
  }

  # Custom UI text
  user_pool_add_ons {
    advanced_security_mode = "AUDIT"
  }

  tags = var.tags
}

# ==============================================================================
# COGNITO DOMAIN (Hosted UI)
# ==============================================================================

resource "random_string" "cognito_domain_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_cognito_user_pool_domain" "ollama" {
  domain       = "${var.project_name}-llm-${random_string.cognito_domain_suffix.result}"
  user_pool_id = aws_cognito_user_pool.ollama.id
}

# ==============================================================================
# GROUPS (mapped to Open WebUI roles)
# ==============================================================================

resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.ollama.id
  description  = "Full access — all models, settings, user management"
}

resource "aws_cognito_user_group" "user" {
  name         = "user"
  user_pool_id = aws_cognito_user_pool.ollama.id
  description  = "Standard access — default model only"
}

# ==============================================================================
# APP CLIENT (OAuth 2.0 / OIDC for Open WebUI)
# ==============================================================================

resource "aws_cognito_user_pool_client" "webui" {
  name         = "${var.project_name}-webui-client"
  user_pool_id = aws_cognito_user_pool.ollama.id

  # OAuth settings
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  generate_secret                      = true

  # Callback and logout URLs (CloudFront domain)
  callback_urls = ["https://${var.cloudfront_domain}/oauth/oidc/callback"]
  logout_urls   = ["https://${var.cloudfront_domain}"]

  # Token validity
  access_token_validity  = 1   # 1 hour
  id_token_validity      = 1   # 1 hour
  refresh_token_validity = 30  # 30 days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Include groups in ID token
  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]
}

# ==============================================================================
# INITIAL ADMIN USER
# ==============================================================================

resource "aws_cognito_user" "admin" {
  user_pool_id = aws_cognito_user_pool.ollama.id
  username     = var.admin_email

  attributes = {
    email          = var.admin_email
    email_verified = true
  }

  # Cognito sends a temporary password via email
  desired_delivery_mediums = ["EMAIL"]
}

resource "aws_cognito_user_in_group" "admin" {
  user_pool_id = aws_cognito_user_pool.ollama.id
  group_name   = aws_cognito_user_group.admin.name
  username     = aws_cognito_user.admin.username
}

# ==============================================================================
# PRE SIGN-UP LAMBDA — Notifies admin via SNS when new users register
# ==============================================================================

resource "aws_sns_topic" "signup_notifications" {
  name = "${var.project_name}-signup-notifications"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "admin_email" {
  topic_arn = aws_sns_topic.signup_notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role" "pre_signup_lambda" {
  name = "${var.project_name}-cognito-pre-signup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "pre_signup_lambda" {
  name = "sns-publish"
  role = aws_iam_role.pre_signup_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.signup_notifications.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "pre_signup" {
  function_name = "${var.project_name}-cognito-pre-signup"
  role          = aws_iam_role.pre_signup_lambda.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 5

  filename         = data.archive_file.pre_signup.output_path
  source_code_hash = data.archive_file.pre_signup.output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.signup_notifications.arn
    }
  }

  tags = var.tags
}

data "archive_file" "pre_signup" {
  type        = "zip"
  output_path = "${path.module}/lambda/pre_signup.zip"

  source {
    content = <<-PYTHON
import os
import json
import boto3

sns = boto3.client('sns')

def handler(event, context):
    """Pre Sign-up trigger: auto-confirm user and notify admin via SNS."""
    email = event['request']['userAttributes'].get('email', 'unknown')

    # Auto-confirm and auto-verify email
    event['response']['autoConfirmUser'] = True
    event['response']['autoVerifyEmail'] = True

    # Notify admin
    sns.publish(
        TopicArn=os.environ['SNS_TOPIC_ARN'],
        Subject=f'Ollama WebUI — New Access Request: {email}',
        Message=(
            f'A new user has requested access to the Ollama Private LLM platform.\n\n'
            f'Email: {email}\n\n'
            f'To grant access, go to the AWS Cognito Console:\n'
            f'  1. Open Cognito → User Pool → Users\n'
            f'  2. Find the user: {email}\n'
            f'  3. Go to Groups tab → Add to group\n'
            f'  4. Select "user" (standard) or "admin" (full access)\n\n'
            f'The user will be able to access the platform after being added to a group.'
        ),
    )

    return event
PYTHON
    filename = "index.py"
  }
}

# Allow Cognito to invoke the Lambda
resource "aws_lambda_permission" "cognito_pre_signup" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_signup.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.ollama.arn
}

# ==============================================================================
# COGNITO HOSTED UI CUSTOMIZATION
# ==============================================================================

resource "aws_cognito_user_pool_ui_customization" "ollama" {
  user_pool_id = aws_cognito_user_pool.ollama.id
  client_id    = aws_cognito_user_pool_client.webui.id

  css = <<-CSS
    .banner-customizable { background-color: #1a1a2e; }
    .submitButton-customizable { background-color: #0f3460; }
    .submitButton-customizable:hover { background-color: #16213e; }
    .label-customizable { font-weight: bold; }
  CSS

  depends_on = [aws_cognito_user_pool_domain.ollama]
}
