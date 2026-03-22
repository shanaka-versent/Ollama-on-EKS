# Grafana Cognito Module — User Pool with MFA + OAuth for In-Cluster Grafana
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# TEMPORARY: This module exists while AMG (AWS Managed Grafana) SSO access
# is being resolved. Once AMG is accessible, disable in-cluster Grafana
# and remove this module.
#
# Provides centralized authentication for Grafana:
#   - Separate Cognito User Pool (not shared with Open WebUI)
#   - Required TOTP MFA
#   - Groups: admin, viewer (mapped to Grafana roles)
#   - OAuth 2.0 / OIDC via Grafana's generic_oauth provider
#   - Pre Sign-up Lambda for admin notification via SNS

# ==============================================================================
# USER POOL
# ==============================================================================

resource "aws_cognito_user_pool" "grafana" {
  name = "${var.project_name}-grafana"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  mfa_configuration = "ON"
  software_token_mfa_configuration {
    enabled = true
  }

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # Custom invite email — identifies this as the Grafana login
  admin_create_user_config {
    invite_message_template {
      email_subject = "Ollama Grafana — Your Login Credentials"
      email_message = "You have been invited to Ollama Grafana (Monitoring Dashboards).\n\nUsername: {username}\nTemporary password: {####}\n\nLogin at: https://${var.cloudfront_domain}/grafana/\n\nYou will be asked to set a new password and configure MFA on first login."
      sms_message   = "Ollama Grafana — Username: {username}, Password: {####}"
    }
  }

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

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  lambda_config {
    pre_sign_up = aws_lambda_function.grafana_pre_signup.arn
  }

  user_pool_add_ons {
    advanced_security_mode = "AUDIT"
  }

  tags = var.tags
}

# ==============================================================================
# COGNITO DOMAIN (Hosted UI)
# ==============================================================================

resource "random_string" "grafana_domain_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_cognito_user_pool_domain" "grafana" {
  domain       = "${var.project_name}-grafana-${random_string.grafana_domain_suffix.result}"
  user_pool_id = aws_cognito_user_pool.grafana.id
}

# ==============================================================================
# GROUPS (mapped to Grafana roles via JMESPath)
# ==============================================================================

resource "aws_cognito_user_group" "grafana_admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.grafana.id
  description  = "Grafana Admin — full dashboard and datasource management"
}

resource "aws_cognito_user_group" "grafana_viewer" {
  name         = "viewer"
  user_pool_id = aws_cognito_user_pool.grafana.id
  description  = "Grafana Viewer — read-only dashboard access"
}

# ==============================================================================
# APP CLIENT (OAuth 2.0 / OIDC for Grafana)
# ==============================================================================

resource "aws_cognito_user_pool_client" "grafana" {
  name         = "${var.project_name}-grafana-client"
  user_pool_id = aws_cognito_user_pool.grafana.id

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  generate_secret                      = true

  # Grafana generic_oauth callback
  callback_urls = ["https://${var.cloudfront_domain}/grafana/login/generic_oauth"]
  logout_urls   = ["https://${var.cloudfront_domain}/grafana/login"]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]
}

# ==============================================================================
# INITIAL ADMIN USER
# ==============================================================================

resource "aws_cognito_user" "grafana_admin" {
  user_pool_id = aws_cognito_user_pool.grafana.id
  username     = var.admin_email

  attributes = {
    email          = var.admin_email
    email_verified = true
  }

  desired_delivery_mediums = ["EMAIL"]
}

resource "aws_cognito_user_in_group" "grafana_admin" {
  user_pool_id = aws_cognito_user_pool.grafana.id
  group_name   = aws_cognito_user_group.grafana_admin.name
  username     = aws_cognito_user.grafana_admin.username
}

# ==============================================================================
# PRE SIGN-UP LAMBDA — Notifies admin via SNS
# ==============================================================================

resource "aws_sns_topic" "grafana_signup_notifications" {
  name = "${var.project_name}-grafana-signup-notifications"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "grafana_admin_email" {
  topic_arn = aws_sns_topic.grafana_signup_notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role" "grafana_pre_signup_lambda" {
  name = "${var.project_name}-grafana-pre-signup"

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

resource "aws_iam_role_policy" "grafana_pre_signup_lambda" {
  name = "sns-publish"
  role = aws_iam_role.grafana_pre_signup_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.grafana_signup_notifications.arn
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

resource "aws_lambda_function" "grafana_pre_signup" {
  function_name = "${var.project_name}-grafana-pre-signup"
  role          = aws_iam_role.grafana_pre_signup_lambda.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 5

  filename         = data.archive_file.grafana_pre_signup.output_path
  source_code_hash = data.archive_file.grafana_pre_signup.output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.grafana_signup_notifications.arn
    }
  }

  tags = var.tags
}

data "archive_file" "grafana_pre_signup" {
  type        = "zip"
  output_path = "${path.module}/lambda/grafana_pre_signup.zip"

  source {
    content = <<-PYTHON
import os
import json
import boto3

sns = boto3.client('sns')

def handler(event, context):
    """Pre Sign-up trigger: auto-confirm user and notify admin via SNS."""
    email = event['request']['userAttributes'].get('email', 'unknown')

    event['response']['autoConfirmUser'] = True
    event['response']['autoVerifyEmail'] = True

    sns.publish(
        TopicArn=os.environ['SNS_TOPIC_ARN'],
        Subject=f'Grafana — New Access Request: {email}',
        Message=(
            f'A new user has requested access to Grafana.\n\n'
            f'Email: {email}\n\n'
            f'To grant access, go to the AWS Cognito Console:\n'
            f'  1. Open Cognito → User Pool "ollama-grafana" → Users\n'
            f'  2. Find the user: {email}\n'
            f'  3. Go to Groups tab → Add to group\n'
            f'  4. Select "viewer" (read-only) or "admin" (full access)\n\n'
            f'The user will be able to access Grafana after being added to a group.'
        ),
    )

    return event
PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_permission" "grafana_cognito_pre_signup" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.grafana_pre_signup.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.grafana.arn
}

# ==============================================================================
# COGNITO HOSTED UI CUSTOMIZATION
# ==============================================================================

resource "aws_cognito_user_pool_ui_customization" "grafana" {
  user_pool_id = aws_cognito_user_pool.grafana.id
  client_id    = aws_cognito_user_pool_client.grafana.id

  css = <<-CSS
    .banner-customizable { background-color: #4a2f0f; }
    .submitButton-customizable { background-color: #e67e22; }
    .submitButton-customizable:hover { background-color: #d35400; }
    .label-customizable { font-weight: bold; }
  CSS

  depends_on = [aws_cognito_user_pool_domain.grafana]
}
