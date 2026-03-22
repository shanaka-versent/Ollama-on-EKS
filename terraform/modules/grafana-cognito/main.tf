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
#   - Access-granted Lambda for user notification via SES (EventBridge)
#
# Admin flow:
#   1. Terraform creates admin user → receives temp password via email
#   2. Admin logs in → changes password → sets up MFA (TOTP)
#   3. Admin can now access Grafana as admin
#
# New user flow:
#   1. User opens Grafana URL → clicks "Sign in to Grafana"
#   2. Redirected to Cognito hosted UI → clicks "Sign up"
#   3. User enters email + password → account auto-confirmed
#   4. Admin receives SNS notification of new signup
#   5. Admin adds user to group in Cognito Console
#   6. User receives "Access Granted" email via SES
#   7. User logs in → sets up MFA (TOTP) on first login
#   8. User can now access Grafana (role mapped from Cognito group)

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
# ACCESS GRANTED NOTIFICATION — Notifies user via SES when added to a group
# ==============================================================================

resource "aws_ses_email_identity" "grafana_notification_sender" {
  email = var.notification_email
}

resource "aws_cloudwatch_event_rule" "grafana_user_added_to_group" {
  name        = "${var.project_name}-grafana-access-granted"
  description = "Triggers when a user is added to a group in the Grafana Cognito pool"

  event_pattern = jsonencode({
    source      = ["aws.cognito-idp"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["AdminAddUserToGroup"]
      requestParameters = {
        userPoolId = [aws_cognito_user_pool.grafana.id]
      }
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "grafana_access_granted_lambda" {
  rule = aws_cloudwatch_event_rule.grafana_user_added_to_group.name
  arn  = aws_lambda_function.grafana_access_granted.arn
}

resource "aws_lambda_permission" "eventbridge_grafana_access_granted" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.grafana_access_granted.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.grafana_user_added_to_group.arn
}

resource "aws_iam_role" "grafana_access_granted_lambda" {
  name = "${var.project_name}-grafana-access-granted"

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

resource "aws_iam_role_policy" "grafana_access_granted_lambda" {
  name = "ses-send-and-cognito-read"
  role = aws_iam_role.grafana_access_granted_lambda.id

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
        Resource = aws_cognito_user_pool.grafana.arn
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

resource "aws_lambda_function" "grafana_access_granted" {
  function_name = "${var.project_name}-grafana-access-granted"
  role          = aws_iam_role.grafana_access_granted_lambda.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 10

  filename         = data.archive_file.grafana_access_granted.output_path
  source_code_hash = data.archive_file.grafana_access_granted.output_base64sha256

  environment {
    variables = {
      USER_POOL_ID = aws_cognito_user_pool.grafana.id
      SENDER_EMAIL = var.notification_email
      APP_NAME     = "Ollama Grafana"
      LOGIN_URL    = "https://${var.cloudfront_domain}/grafana/"
    }
  }

  tags = var.tags
}

data "archive_file" "grafana_access_granted" {
  type        = "zip"
  output_path = "${path.module}/lambda/grafana_access_granted.zip"

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
    role_desc = 'full access (admin)' if group_name == 'admin' else 'read-only (viewer)'

    try:
        ses.send_email(
            Source=os.environ['SENDER_EMAIL'],
            Destination={'ToAddresses': [email]},
            Message={
                'Subject': {'Data': f'{app_name} — Access Granted'},
                'Body': {
                    'Text': {'Data': (
                        f'Your access to {app_name} (Monitoring Dashboards) has been approved.\n\n'
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
