# Cognito Module — User Pool with MFA + OAuth for Open WebUI
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Provides centralized authentication for Open WebUI:
#   - Cognito User Pool with required TOTP MFA
#   - Groups: admin, user (mapped to Open WebUI roles)
#   - OAuth 2.0 / OIDC app client for Open WebUI
#   - Cognito domain (for OAuth authorization code exchange only)
#   - Pre Sign-up Lambda for admin notification via SNS
#   - Access-granted Lambda for user notification via SES (EventBridge)
#   - Initial admin user (receives temp password via email)
#
# NOTE: Users NEVER see the Cognito hosted UI. All login, signup, password
# change, MFA enrollment, and forgot password flows are handled by the custom
# login portal (auth_proxy Lambda + login.html SPA). The Cognito domain is
# kept only for the server-side OAuth/OIDC authorization code exchange.
#
# Admin flow:
#   1. Terraform creates admin user → receives temp password via email
#   2. Admin visits custom login page → enters temp password
#   3. Portal detects NEW_PASSWORD_REQUIRED → shows password change form
#   4. Portal detects MFA_SETUP → shows QR code for TOTP enrollment
#   5. Admin can now access Open WebUI as admin
#
# New user flow:
#   1. User opens CloudFront URL → custom login page loads
#   2. User clicks "Request Access" → fills signup form
#   3. Custom portal calls Cognito SignUp API → account auto-confirmed
#   4. Admin receives SNS notification of new signup
#   5. Admin adds user to group in Cognito Console
#   6. User receives "Access Granted" email via SES
#   7. User logs in → sets up MFA (TOTP) on first login via custom portal
#   8. User can now access Open WebUI (role mapped from Cognito group)

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

  # Schema: email and name are required (shown on Cognito signup form)
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

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 256
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
# COGNITO DOMAIN (required for OAuth authorization code exchange)
# ==============================================================================
# The domain is kept for the server-side OAuth/OIDC flow (auth_proxy Lambda
# uses it to exchange authorization codes). Users never see the hosted UI.

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

  # Auth flows — USER_PASSWORD_AUTH needed for custom login portal (InitiateAuth API)
  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
  ]
}

# ==============================================================================
# PUBLIC APP CLIENT (for custom signup form — no client secret)
# ==============================================================================
# Used by the custom login page to call the Cognito SignUp API directly.
# No secret required — signup is public (Pre Sign-up Lambda auto-confirms,
# but admin must add user to a group before they can access the app).

resource "aws_cognito_user_pool_client" "signup_public" {
  name         = "${var.project_name}-signup-public"
  user_pool_id = aws_cognito_user_pool.ollama.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
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
    name           = split("@", var.admin_email)[0]
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
# ACCESS GRANTED NOTIFICATION — Notifies user via SES when added to a group
# ==============================================================================
# EventBridge captures CloudTrail management events (no explicit trail needed).
# When admin adds a user to a group, Lambda sends "Access Granted" email via SES.
# NOTE: SES must be out of sandbox mode OR recipient email must be verified.

resource "aws_ses_email_identity" "notification_sender" {
  email = var.notification_email
}

resource "aws_cloudwatch_event_rule" "user_added_to_group" {
  name        = "${var.project_name}-webui-access-granted"
  description = "Triggers when a user is added to a group in the WebUI Cognito pool"

  event_pattern = jsonencode({
    source      = ["aws.cognito-idp"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["AdminAddUserToGroup"]
      requestParameters = {
        userPoolId = [aws_cognito_user_pool.ollama.id]
      }
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "access_granted_lambda" {
  rule = aws_cloudwatch_event_rule.user_added_to_group.name
  arn  = aws_lambda_function.access_granted.arn
}

resource "aws_lambda_permission" "eventbridge_access_granted" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.access_granted.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.user_added_to_group.arn
}

resource "aws_iam_role" "access_granted_lambda" {
  name = "${var.project_name}-webui-access-granted"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "access_granted_lambda" {
  name = "ses-send-and-cognito-read"
  role = aws_iam_role.access_granted_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ses:SendEmail"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "cognito-idp:AdminGetUser"
        Resource = aws_cognito_user_pool.ollama.arn
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

resource "aws_lambda_function" "access_granted" {
  function_name = "${var.project_name}-webui-access-granted"
  role          = aws_iam_role.access_granted_lambda.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 10

  filename         = data.archive_file.access_granted.output_path
  source_code_hash = data.archive_file.access_granted.output_base64sha256

  environment {
    variables = {
      USER_POOL_ID = aws_cognito_user_pool.ollama.id
      SENDER_EMAIL = var.notification_email
      APP_NAME     = "Ollama Open WebUI"
      LOGIN_URL    = "https://${var.cloudfront_domain}/"
    }
  }

  tags = var.tags
}

data "archive_file" "access_granted" {
  type        = "zip"
  output_path = "${path.module}/lambda/access_granted.zip"

  source {
    content = <<-PYTHON
import os
import json
import boto3

cognito = boto3.client('cognito-idp')
ses = boto3.client('ses')

def handler(event, context):
    """Notifies user via SES when added to a Cognito group."""
    detail = event.get('detail', {})
    params = detail.get('requestParameters', {})

    username = params.get('username', '')
    group_name = params.get('groupName', '')
    user_pool_id = os.environ['USER_POOL_ID']

    # Get user email from Cognito
    try:
        user = cognito.admin_get_user(
            UserPoolId=user_pool_id,
            Username=username
        )
        email = next(
            (a['Value'] for a in user['UserAttributes'] if a['Name'] == 'email'),
            None
        )
    except Exception as e:
        print(f'Failed to get user: {e}')
        return

    if not email:
        print(f'No email found for user: {username}')
        return

    app_name = os.environ['APP_NAME']
    login_url = os.environ['LOGIN_URL']
    role_desc = 'full access (admin)' if group_name == 'admin' else 'standard access'

    try:
        ses.send_email(
            Source=os.environ['SENDER_EMAIL'],
            Destination={'ToAddresses': [email]},
            Message={
                'Subject': {'Data': f'{app_name} — Access Granted'},
                'Body': {
                    'Text': {'Data': (
                        f'Your access to {app_name} has been approved.\n\n'
                        f'Role: {group_name} ({role_desc})\n\n'
                        f'You can now log in at:\n{login_url}\n\n'
                        f'On first login, you will be asked to set up MFA '
                        f'(authenticator app).\n\n'
                        f'If you have any issues, contact your administrator.'
                    )}
                }
            }
        )
        print(f'Access-granted email sent to {email} for {app_name} ({group_name})')
    except Exception as e:
        print(f'Failed to send email via SES: {e}')
        print('Ensure SES sender is verified and account is out of sandbox mode.')
PYTHON
    filename = "index.py"
  }
}

# NOTE: Cognito hosted UI customization removed — all login/signup/password flows
# are handled by the custom login portal (auth_proxy Lambda + login.html SPA).
# The Cognito domain is kept for the OAuth/OIDC flow (authorization code exchange)
# but users never see the Cognito hosted UI directly.
