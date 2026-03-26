# AWS Cost Protection Stack v2
# @author Shanaka Jayasundera - shanaka.jayasundera@versent.com.au
# @company Versent — Modernisation Practice
#
# 9-layer cost protection with auto-discovery circuit breaker.
# When costs spike, the circuit breaker Lambda discovers and disables
# every serverless resource in the account to stop the bleeding.
#
# Layers:
#   1. AWS Budgets — monthly + daily early warning
#   2. Cost Anomaly Detection — ML-based unusual spend detection
#   3. CloudWatch Billing Alarms — daily total + per-service (us-east-1)
#   4. Circuit Breaker Lambda — auto-discovery kill switch
#   5. Lambda Concurrency Guards — preventive (set per-function)
#   6. API Gateway Throttling — preventive (set per-API)
#   7. DLQ Watchdog — auto-disables Lambda stuck in failure loops
#   8. GPU Node Monitor — alerts if GPU node runs > 2 hours
#   9. NAT Gateway Monitor — alerts on data transfer spikes
#
# Cost: < $1/month

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

# ==============================================================================
# PROVIDERS
# ==============================================================================

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

# Billing metrics (AWS/Billing namespace) are ONLY available in us-east-1,
# regardless of where your resources run. This is an AWS-wide limitation.
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

# ==============================================================================
# VARIABLES
# ==============================================================================

variable "aws_region" {
  description = "Primary AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "aws_profile" {
  description = "AWS CLI profile name (null to use default credentials chain)"
  type        = string
  default     = null
}

variable "alert_email" {
  description = "Email address for cost alerts and circuit breaker notifications"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., production, dev)"
  type        = string
  default     = "production"
}

variable "monthly_budget_amount" {
  description = "Monthly budget cap in USD"
  type        = number
  default     = 200
}

variable "daily_budget_amount" {
  description = "Daily early-warning budget in USD (separate from billing alarm threshold)"
  type        = number
  default     = 10
}

variable "daily_cost_threshold" {
  description = "Daily CloudWatch billing alarm threshold in USD (triggers circuit breaker)"
  type        = number
  default     = 50
}

variable "anomaly_threshold" {
  description = "Cost anomaly detection threshold in USD"
  type        = number
  default     = 20
}

variable "eks_cluster_name" {
  description = "EKS cluster name for GPU node monitoring"
  type        = string
  default     = "eks-ollama-dev"
}

variable "gpu_node_max_hours" {
  description = "Alert if GPU node runs longer than this many hours (KEDA+Karpenter should scale to zero in ~25 min)"
  type        = number
  default     = 4
}

variable "lambda_cost_threshold" {
  description = "Daily Lambda service spend alarm threshold in USD"
  type        = number
  default     = 5
}

variable "ec2_cost_threshold" {
  description = "Daily EC2 service spend alarm threshold in USD"
  type        = number
  default     = 30
}

variable "nat_gw_cost_threshold" {
  description = "Daily NAT Gateway / VPC spend alarm threshold in USD"
  type        = number
  default     = 10
}

variable "api_gw_cost_threshold" {
  description = "Daily API Gateway spend alarm threshold in USD"
  type        = number
  default     = 5
}

variable "api_gw_request_threshold" {
  description = "API Gateway 5xx error count threshold per 5 minutes (catches runaway loops fast)"
  type        = number
  default     = 100
}

variable "nat_gw_data_threshold_gb" {
  description = "NAT Gateway data transfer alert threshold in GB per hour"
  type        = number
  default     = 5
}

variable "circuit_breaker_dry_run" {
  description = "When true, circuit breaker logs actions but does NOT disable resources"
  type        = bool
  default     = true
}

variable "exempt_lambda_functions" {
  description = "Lambda function names to ALWAYS exempt from circuit breaker (in addition to self-protection)"
  type        = list(string)
  default     = []
}

variable "exempt_api_gateway_ids" {
  description = "REST API Gateway IDs to exempt from circuit breaker throttling"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Always exempt the cost protection Lambdas + user-specified Lambdas
  all_exempt_lambdas = distinct(concat(
    var.exempt_lambda_functions,
    ["cost-circuit-breaker", "cost-dlq-watchdog"]
  ))
}

# ==============================================================================
# DATA SOURCES
# ==============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ==============================================================================
# LAYER 1: AWS BUDGETS
# ==============================================================================
# Monthly budget with alerts at 50%, 80%, 100% + forecasted overspend.
# Daily early warning budget catches spikes before the monthly budget fires.

resource "aws_sns_topic" "budget_alerts" {
  name = "budget-threshold-alerts"
}

resource "aws_sns_topic_subscription" "budget_email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_policy" "budget_alerts" {
  arn = aws_sns_topic.budget_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowBudgetsPublish"
        Effect    = "Allow"
        Principal = { Service = "budgets.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.budget_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# Monthly budget — alerts at 50%, 80%, 100% actual + 100% forecasted
resource "aws_budgets_budget" "monthly" {
  name         = "monthly-cost-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }
}

# Daily early warning budget — catches spikes before monthly budget fires
# Set lower than daily_cost_threshold so you get warned before the circuit breaker fires
resource "aws_budgets_budget" "daily" {
  name         = "daily-cost-early-warning"
  budget_type  = "COST"
  limit_amount = var.daily_budget_amount
  limit_unit   = "USD"
  time_unit    = "DAILY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }
}

# ==============================================================================
# LAYER 2: COST ANOMALY DETECTION
# ==============================================================================
# ML-based detection of unusual spending patterns. Catches cost patterns
# that fixed-threshold budgets miss (e.g., gradual creep, new services).

resource "aws_ce_anomaly_monitor" "account" {
  name              = "account-cost-anomaly-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "alerts" {
  name = "cost-anomaly-alerts"

  monitor_arn_list = [aws_ce_anomaly_monitor.account.arn]

  frequency = "IMMEDIATE"

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold)]
    }
  }

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.cost_alerts.arn
  }
}

# ==============================================================================
# LAYER 3: CLOUDWATCH BILLING ALARMS (us-east-1)
# ==============================================================================
# Billing metrics only exist in us-east-1. These alarms trigger the circuit
# breaker Lambda via SNS cross-region subscription.

# Main cost alerts SNS topic — triggers circuit breaker + sends email
resource "aws_sns_topic" "cost_alerts" {
  name = "cost-protection-alerts"
}

resource "aws_sns_topic_subscription" "cost_alerts_email" {
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_policy" "cost_alerts" {
  arn = aws_sns_topic.cost_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.cost_alerts.arn
      },
      {
        Sid       = "AllowCostAnomalyPublish"
        Effect    = "Allow"
        Principal = { Service = "costalerts.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.cost_alerts.arn
      },
      {
        Sid       = "AllowCrossRegionCloudWatch"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.cost_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# SNS topic in us-east-1 for billing alarms (billing metrics only exist there)
resource "aws_sns_topic" "billing_alarms_use1" {
  provider = aws.us_east_1
  name     = "billing-alarm-triggers"
}

resource "aws_sns_topic_policy" "billing_alarms_use1" {
  provider = aws.us_east_1
  arn      = aws_sns_topic.billing_alarms_use1.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.billing_alarms_use1.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# Forward billing alarm SNS to circuit breaker Lambda
resource "aws_sns_topic_subscription" "billing_to_circuit_breaker" {
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.billing_alarms_use1.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.circuit_breaker.arn
}

# Email subscription for billing alarms too
resource "aws_sns_topic_subscription" "billing_email" {
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.billing_alarms_use1.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Daily estimated charges alarm
resource "aws_cloudwatch_metric_alarm" "daily_estimated_charges" {
  provider            = aws.us_east_1
  alarm_name          = "daily-estimated-charges-${var.daily_cost_threshold}usd"
  alarm_description   = "Estimated charges exceeded $${var.daily_cost_threshold}/day"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600 # 6 hours
  statistic           = "Maximum"
  threshold           = var.daily_cost_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.billing_alarms_use1.arn]
  ok_actions    = [aws_sns_topic.billing_alarms_use1.arn]
}

# Per-service billing alarms — Lambda
resource "aws_cloudwatch_metric_alarm" "lambda_spend" {
  provider            = aws.us_east_1
  alarm_name          = "lambda-daily-spend-${var.lambda_cost_threshold}usd"
  alarm_description   = "Lambda service spend exceeds $${var.lambda_cost_threshold}/day"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600
  statistic           = "Maximum"
  threshold           = var.lambda_cost_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency    = "USD"
    ServiceName = "AWS Lambda"
  }

  alarm_actions = [aws_sns_topic.billing_alarms_use1.arn]
}

# Per-service billing alarms — EC2 (includes GPU nodes)
resource "aws_cloudwatch_metric_alarm" "ec2_spend" {
  provider            = aws.us_east_1
  alarm_name          = "ec2-daily-spend-${var.ec2_cost_threshold}usd"
  alarm_description   = "EC2 service spend exceeds $${var.ec2_cost_threshold}/day. Check GPU node runtime."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600
  statistic           = "Maximum"
  threshold           = var.ec2_cost_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency    = "USD"
    ServiceName = "Amazon Elastic Compute Cloud - Compute"
  }

  alarm_actions = [aws_sns_topic.billing_alarms_use1.arn]
}

# Per-service billing alarms — NAT Gateway / VPC
resource "aws_cloudwatch_metric_alarm" "natgw_spend" {
  provider            = aws.us_east_1
  alarm_name          = "natgw-daily-spend-${var.nat_gw_cost_threshold}usd"
  alarm_description   = "VPC/NAT Gateway spend exceeds $${var.nat_gw_cost_threshold}/day"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600
  statistic           = "Maximum"
  threshold           = var.nat_gw_cost_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency    = "USD"
    ServiceName = "Amazon Virtual Private Cloud"
  }

  alarm_actions = [aws_sns_topic.billing_alarms_use1.arn]
}

# Per-service billing alarms — API Gateway (cost-based, ~6 hour detection)
resource "aws_cloudwatch_metric_alarm" "apigw_spend" {
  provider            = aws.us_east_1
  alarm_name          = "apigw-daily-spend-${var.api_gw_cost_threshold}usd"
  alarm_description   = "API Gateway spend exceeds $${var.api_gw_cost_threshold}/day"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600
  statistic           = "Maximum"
  threshold           = var.api_gw_cost_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency    = "USD"
    ServiceName = "Amazon API Gateway"
  }

  alarm_actions = [aws_sns_topic.billing_alarms_use1.arn]
}

# API Gateway — 5xx error spike alarm (fast detection, ~5 minutes)
# This catches runaway loops, misconfigured integrations, or abuse much faster
# than the billing alarm. Works across ALL API Gateways in the account.
# Uses the account-level metric (no ApiName dimension = aggregated across all APIs).
resource "aws_cloudwatch_metric_alarm" "apigw_5xx_errors" {
  alarm_name          = "apigw-5xx-error-spike"
  alarm_description   = <<-EOT
    API Gateway 5xx errors exceeded ${var.api_gw_request_threshold} in 5 minutes.
    This indicates backend failures across one or more APIs. Check API Gateway
    CloudWatch logs and Lambda function errors.
  EOT
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2  # 2 consecutive 5-min periods = 10 min sustained
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 300  # 5 minutes
  statistic           = "Sum"
  threshold           = var.api_gw_request_threshold
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cost_alerts.arn]
}

# API Gateway — request count spike alarm (fast detection, ~5 minutes)
# Catches unexpected traffic surges that could drive Lambda costs.
# Threshold is 10x the normal burst limit (default 20 burst * 300s = 6000 per period).
resource "aws_cloudwatch_metric_alarm" "apigw_request_spike" {
  alarm_name          = "apigw-request-count-spike"
  alarm_description   = <<-EOT
    API Gateway received over 10,000 requests in 5 minutes across all APIs.
    This could indicate abuse, runaway clients, or misconfigured retry loops.
    Check API Gateway CloudWatch metrics per-API to identify the source.
  EOT
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Count"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 10000
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cost_alerts.arn]
}

# ==============================================================================
# LAYER 4: CIRCUIT BREAKER LAMBDA
# ==============================================================================
# The kill switch. Auto-discovers and disables all serverless resources.
# Triggered by CloudWatch billing alarms and cost anomaly detection.

data "archive_file" "circuit_breaker" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/circuit_breaker"
  output_path = "${path.module}/lambda/circuit_breaker.zip"
}

resource "aws_lambda_function" "circuit_breaker" {
  function_name    = "cost-circuit-breaker"
  description      = "Auto-discovery cost circuit breaker — disables all serverless resources on cost spike"
  filename         = data.archive_file.circuit_breaker.output_path
  source_code_hash = data.archive_file.circuit_breaker.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256

  reserved_concurrent_executions = 5

  environment {
    variables = {
      DRY_RUN                = var.circuit_breaker_dry_run ? "true" : "false"
      SNS_TOPIC_ARN          = aws_sns_topic.cost_alerts.arn
      SELF_FUNCTION_NAME     = "cost-circuit-breaker"
      WATCHDOG_FUNCTION_NAME = "cost-dlq-watchdog"
      EXEMPT_LAMBDAS         = jsonencode(local.all_exempt_lambdas)
      EXEMPT_API_GW_IDS      = jsonencode(var.exempt_api_gateway_ids)
      AWS_ACCOUNT_ID         = local.account_id
    }
  }

  role = aws_iam_role.circuit_breaker.arn

  depends_on = [aws_cloudwatch_log_group.circuit_breaker]

  tags = {
    CostProtection = "exempt"
  }
}

resource "aws_cloudwatch_log_group" "circuit_breaker" {
  name              = "/aws/lambda/cost-circuit-breaker"
  retention_in_days = 30
}

# Allow SNS (primary region) to invoke the circuit breaker
resource "aws_lambda_permission" "circuit_breaker_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.circuit_breaker.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cost_alerts.arn
}

# Allow SNS (us-east-1 billing alarms) to invoke the circuit breaker
resource "aws_lambda_permission" "circuit_breaker_sns_use1" {
  statement_id  = "AllowSNSInvokeUSE1"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.circuit_breaker.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.billing_alarms_use1.arn
}

# SNS subscription — cost alerts trigger circuit breaker
resource "aws_sns_topic_subscription" "cost_alerts_to_circuit_breaker" {
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.circuit_breaker.arn
}

# IAM role for circuit breaker Lambda
resource "aws_iam_role" "circuit_breaker" {
  name = "cost-circuit-breaker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "circuit_breaker" {
  name = "cost-circuit-breaker-policy"
  role = aws_iam_role.circuit_breaker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaAutoDiscover"
        Effect = "Allow"
        Action = [
          "lambda:ListFunctions",
          "lambda:ListTags",
          "lambda:GetFunction",
          "lambda:PutFunctionConcurrency",
          "lambda:DeleteFunctionConcurrency"
        ]
        Resource = "*"
      },
      {
        Sid    = "APIGatewayAutoDiscover"
        Effect = "Allow"
        Action = [
          "apigateway:GET",
          "apigateway:PATCH"
        ]
        Resource = "*"
      },
      {
        Sid    = "EventBridgeAutoDiscover"
        Effect = "Allow"
        Action = [
          "events:ListRules",
          "events:DisableRule",
          "events:EnableRule",
          "events:ListTagsForResource"
        ]
        Resource = "*"
      },
      {
        Sid    = "StepFunctionsAutoDiscover"
        Effect = "Allow"
        Action = [
          "states:ListStateMachines",
          "states:ListExecutions",
          "states:StopExecution",
          "states:ListTagsForResource"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECSAutoDiscover"
        Effect = "Allow"
        Action = [
          "ecs:ListClusters",
          "ecs:ListServices",
          "ecs:DescribeServices",
          "ecs:UpdateService",
          "ecs:ListTagsForResource"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2TaggedStop"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StopInstances"
        ]
        Resource = "*"
      },
      {
        Sid    = "SNSNotify"
        Effect = "Allow"
        Action = "sns:Publish"
        Resource = aws_sns_topic.cost_alerts.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# ==============================================================================
# LAYER 7: DLQ WATCHDOG LAMBDA
# ==============================================================================
# Monitors DLQ depth alarms. When a DLQ alarm fires, extracts the function
# name from the alarm name pattern "{function-name}-dlq-breach" and sets
# that function's concurrency to 0 to stop the failure loop.

data "archive_file" "dlq_watchdog" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/dlq_watchdog"
  output_path = "${path.module}/lambda/dlq_watchdog.zip"
}

resource "aws_lambda_function" "dlq_watchdog" {
  function_name    = "cost-dlq-watchdog"
  description      = "DLQ failure loop watchdog — auto-disables Lambda functions stuck in retry loops"
  filename         = data.archive_file.dlq_watchdog.output_path
  source_code_hash = data.archive_file.dlq_watchdog.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 128

  reserved_concurrent_executions = 5

  environment {
    variables = {
      SNS_TOPIC_ARN  = aws_sns_topic.cost_alerts.arn
      DRY_RUN        = var.circuit_breaker_dry_run ? "true" : "false"
      EXEMPT_LAMBDAS = jsonencode(local.all_exempt_lambdas)
    }
  }

  role = aws_iam_role.dlq_watchdog.arn

  depends_on = [aws_cloudwatch_log_group.dlq_watchdog]

  tags = {
    CostProtection = "exempt"
  }
}

resource "aws_cloudwatch_log_group" "dlq_watchdog" {
  name              = "/aws/lambda/cost-dlq-watchdog"
  retention_in_days = 30
}

resource "aws_lambda_permission" "dlq_watchdog_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dlq_watchdog.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cost_alerts.arn
}

# DLQ watchdog also subscribes to cost_alerts SNS — it filters for DLQ alarms
resource "aws_sns_topic_subscription" "cost_alerts_to_dlq_watchdog" {
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.dlq_watchdog.arn
}

resource "aws_iam_role" "dlq_watchdog" {
  name = "cost-dlq-watchdog-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "dlq_watchdog" {
  name = "cost-dlq-watchdog-policy"
  role = aws_iam_role.dlq_watchdog.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaConcurrency"
        Effect = "Allow"
        Action = [
          "lambda:PutFunctionConcurrency",
          "lambda:GetFunction"
        ]
        Resource = "*"
      },
      {
        Sid    = "SNSNotify"
        Effect = "Allow"
        Action = "sns:Publish"
        Resource = aws_sns_topic.cost_alerts.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# ==============================================================================
# LAYER 8: GPU NODE MONITOR
# ==============================================================================
# Alerts if EKS cluster has GPU nodes running longer than expected.
# The Ollama stack uses KEDA (15-min idle) + Karpenter (10-min consolidation)
# to auto-scale GPU to zero after ~25 min. If this alarm fires continuously,
# scale-to-zero is likely broken.
#
# Uses ContainerInsights node_count metric. Requires Container Insights
# enabled on the EKS cluster (EKS Auto Mode enables this by default).
# The alarm fires if node_count > 1 for gpu_node_max_hours consecutive hours,
# meaning a GPU node has been running alongside the always-on system node.

resource "aws_cloudwatch_metric_alarm" "gpu_node_runtime" {
  alarm_name          = "gpu-node-running-over-${var.gpu_node_max_hours}h"
  alarm_description   = <<-EOT
    GPU node in EKS cluster ${var.eks_cluster_name} has been running for over
    ${var.gpu_node_max_hours} hours. KEDA + Karpenter should scale to zero after
    ~25 min idle. Check: kubectl get nodes -l karpenter.sh/nodepool=gpu-ollama
  EOT
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.gpu_node_max_hours # Each period = 1 hour
  metric_name         = "node_count"
  namespace           = "ContainerInsights"
  period              = 3600 # 1 hour
  statistic           = "Maximum"
  threshold           = 1   # Alert if > 1 node (system node is always 1)
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.cost_alerts.arn]
  ok_actions    = [aws_sns_topic.cost_alerts.arn]
}

# ==============================================================================
# LAYER 9: NAT GATEWAY MONITOR
# ==============================================================================
# Alerts on NAT Gateway data transfer spikes (>5 GB/hour default).
# Catches pod pull loops, misconfigured egress, or data exfil.

resource "aws_cloudwatch_metric_alarm" "nat_gw_bytes_out" {
  alarm_name          = "nat-gateway-data-transfer-spike"
  alarm_description   = "NAT Gateway outbound data exceeds ${var.nat_gw_data_threshold_gb} GB/hour. Possible pod pull loop or misconfigured egress."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "BytesOutToDestination"
  namespace           = "AWS/NATGateway"
  period              = 3600
  statistic           = "Sum"
  # Convert GB to bytes
  threshold           = var.nat_gw_data_threshold_gb * 1073741824
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cost_alerts.arn]
}

# ==============================================================================
# OUTPUTS
# ==============================================================================

output "cost_alerts_sns_arn" {
  description = "SNS topic ARN for cost protection alerts"
  value       = aws_sns_topic.cost_alerts.arn
}

output "budget_alerts_sns_arn" {
  description = "SNS topic ARN for budget threshold alerts"
  value       = aws_sns_topic.budget_alerts.arn
}

output "circuit_breaker_function_name" {
  description = "Circuit breaker Lambda function name"
  value       = aws_lambda_function.circuit_breaker.function_name
}

output "circuit_breaker_dry_run" {
  description = "Whether circuit breaker is in dry run mode"
  value       = var.circuit_breaker_dry_run
}

output "dlq_watchdog_function_name" {
  description = "DLQ watchdog Lambda function name"
  value       = aws_lambda_function.dlq_watchdog.function_name
}

output "monthly_budget_amount" {
  description = "Monthly budget cap in USD"
  value       = var.monthly_budget_amount
}

output "daily_cost_threshold" {
  description = "Daily billing alarm threshold in USD"
  value       = var.daily_cost_threshold
}
