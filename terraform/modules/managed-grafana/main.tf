# AWS Managed Grafana Module
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Replaces self-managed in-cluster Grafana with AWS Managed Grafana (AMG).
# Benefits: SSO login, no port-forward, managed HA, cleaner EKS cluster.
# Prometheus + DCGM Exporter remain in-cluster; AMG reads via AMP.
#
# Prerequisites:
#   - IAM Identity Center (AWS SSO) must be enabled in the account
#   - AMP workspace for Prometheus remote write (created by this module)
#
# Cost: ~$9-14/mo (AMG editor license + AMP ingestion)

# ==============================================================================
# AMAZON MANAGED SERVICE FOR PROMETHEUS (AMP)
# ==============================================================================
# AMP acts as the bridge: in-cluster Prometheus remote-writes to AMP,
# and AMG reads from AMP. This avoids direct VPC connectivity issues.

resource "aws_prometheus_workspace" "ollama" {
  alias = "${var.project_name}-prometheus"
  tags  = var.tags
}

# IRSA role for Prometheus remote write to AMP
resource "aws_iam_role" "prometheus_remote_write" {
  name = "${var.project_name}-prometheus-amp-write"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.eks_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(var.eks_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:monitoring:kube-prometheus-stack-prometheus"
          "${replace(var.eks_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "prometheus_remote_write" {
  name = "amp-remote-write"
  role = aws_iam_role.prometheus_remote_write.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:RemoteWrite",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata"
      ]
      Resource = aws_prometheus_workspace.ollama.arn
    }]
  })
}

# ==============================================================================
# AWS MANAGED GRAFANA (AMG)
# ==============================================================================

resource "aws_grafana_workspace" "ollama" {
  name                     = "${var.project_name}-grafana"
  description              = "Ollama LLM Platform - Managed Grafana"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana_workspace.arn

  data_sources = ["PROMETHEUS", "CLOUDWATCH"]

  configuration = jsonencode({
    plugins = {
      pluginAdminEnabled = false
    }
    unifiedAlerting = {
      enabled = true
    }
  })

  tags = var.tags
}

# IAM role for the Grafana workspace (read AMP + CloudWatch)
resource "aws_iam_role" "grafana_workspace" {
  name = "${var.project_name}-amg-workspace"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "grafana.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = var.tags
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "grafana_amp_read" {
  name = "amp-read"
  role = aws_iam_role.grafana_workspace.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:ListWorkspaces",
        "aps:DescribeWorkspace",
        "aps:QueryMetrics",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "grafana_cloudwatch_read" {
  name = "cloudwatch-read"
  role = aws_iam_role.grafana_workspace.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetInsightRuleReport"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:GetLogGroupFields",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["tag:GetResources"]
        Resource = "*"
      }
    ]
  })
}

# ==============================================================================
# SSO ROLE ASSOCIATIONS
# ==============================================================================

resource "aws_grafana_role_association" "admin" {
  count        = length(var.admin_user_ids) > 0 ? 1 : 0
  role         = "ADMIN"
  user_ids     = var.admin_user_ids
  workspace_id = aws_grafana_workspace.ollama.id
}

resource "aws_grafana_role_association" "viewer" {
  count        = length(var.viewer_group_ids) > 0 ? 1 : 0
  role         = "VIEWER"
  group_ids    = var.viewer_group_ids
  workspace_id = aws_grafana_workspace.ollama.id
}
