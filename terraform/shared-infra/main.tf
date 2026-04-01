# Shared Infrastructure — AMG + AMP (persistent across stack creates)
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# This config creates AMG and AMP ONCE. Both Hybrid-LLM and local LLM
# stacks remote-write to the shared AMP workspace, and all dashboards
# appear in the same AMG.
#
# Usage:
#   cd terraform/shared-infra
#   terraform init
#   terraform apply
#
# Then pass the outputs to each stack:
#   amp_remote_write_endpoint = "<output from here>"
#
# To destroy (only when you no longer need any dashboards):
#   terraform destroy

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  backend "s3" {
    bucket         = "ollama-eks-tfstate-183758910727"
    key            = "shared-infra/terraform.tfstate"
    region         = "ap-southeast-2"
    encrypt        = true
    dynamodb_table = "ollama-eks-tfstate-lock"
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

variable "region" {
  default = "ap-southeast-2"
}

variable "project_name" {
  default = "ollama"
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "Ollama-Private-LLM"
    ManagedBy = "terraform-shared-infra"
  }
}

# ==============================================================================
# AMAZON MANAGED SERVICE FOR PROMETHEUS (AMP)
# ==============================================================================

resource "aws_prometheus_workspace" "shared" {
  alias = "${var.project_name}-shared-prometheus"
  tags  = var.tags
}

# ==============================================================================
# AWS MANAGED GRAFANA (AMG)
# ==============================================================================

resource "aws_grafana_workspace" "shared" {
  name                     = "${var.project_name}-grafana"
  description              = "Ollama LLM Platform - Shared Managed Grafana (persistent)"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn

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

# IAM role for Grafana workspace (read AMP + CloudWatch)
resource "aws_iam_role" "grafana" {
  name = "${var.project_name}-shared-amg"

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

resource "aws_iam_role_policy" "grafana_read" {
  name = "amp-cloudwatch-read"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
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
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetInsightRuleReport"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups", "logs:GetLogGroupFields", "logs:StartQuery", "logs:StopQuery", "logs:GetQueryResults", "logs:GetLogEvents"]
        Resource = "*"
      }
    ]
  })
}

# ==============================================================================
# OUTPUTS — pass these to each stack's terraform.tfvars
# ==============================================================================

output "amp_remote_write_endpoint" {
  description = "AMP remote write endpoint — set this in each stack's terraform.tfvars"
  value       = "${aws_prometheus_workspace.shared.prometheus_endpoint}api/v1/remote_write"
}

output "amp_workspace_id" {
  description = "AMP workspace ID"
  value       = aws_prometheus_workspace.shared.id
}

output "amp_query_endpoint" {
  description = "AMP query endpoint (for manual Grafana datasource setup)"
  value       = aws_prometheus_workspace.shared.prometheus_endpoint
}

output "grafana_url" {
  description = "AMG workspace URL (SSO login)"
  value       = "https://${aws_grafana_workspace.shared.endpoint}"
}

output "grafana_workspace_id" {
  description = "AMG workspace ID"
  value       = aws_grafana_workspace.shared.id
}

output "instructions" {
  description = "How to wire this into your stacks"
  value       = <<-EOT

    Add these to each stack's terraform.tfvars:

      amp_remote_write_endpoint = "${aws_prometheus_workspace.shared.prometheus_endpoint}api/v1/remote_write"

    Then deploy your stack normally. Prometheus will remote-write to the
    shared AMP, and all dashboards appear in the shared AMG at:

      https://${aws_grafana_workspace.shared.endpoint}

    Run scripts/setup-amg.sh once to configure the AMP datasource in AMG.
  EOT
}
