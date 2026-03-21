# Bedrock Integration Module — Stack B Only
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Stack B (Hybrid) resources for AWS Bedrock access:
#   1. VPC Endpoint for bedrock-runtime (Interface type, private DNS)
#   2. IRSA role for orchestrator service account
#   3. IAM policy allowing InvokeModel on anthropic.claude-* models
#
# This module is ONLY deployed in Stack B. Stack A has no Bedrock
# credentials, no egress rules, and no API client — it physically
# cannot reach Bedrock.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --- VPC Endpoint for Bedrock Runtime ---
resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.bedrock_endpoint.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-bedrock-runtime-endpoint"
  })
}

# --- Security Group for Bedrock VPC Endpoint ---
resource "aws_security_group" "bedrock_endpoint" {
  name_prefix = "${var.project_name}-bedrock-ep-"
  description = "Security group for Bedrock VPC endpoint — allows HTTPS from orchestrator pods"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from private subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-bedrock-endpoint-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# --- IRSA Role for Bedrock Access ---
module "bedrock_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "ollama-orchestrator-bedrock"

  oidc_providers = {
    main = {
      provider_arn               = var.eks_oidc_provider_arn
      namespace_service_accounts = ["orchestrator:orchestrator-sa"]
    }
  }

  role_policy_arns = {
    bedrock = aws_iam_policy.bedrock_invoke.arn
  }

  tags = var.tags
}

# --- IAM Policy for Bedrock Model Invocation ---
resource "aws_iam_policy" "bedrock_invoke" {
  name        = "${var.project_name}-bedrock-invoke"
  description = "Allow invoking Anthropic Claude models via Bedrock"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/anthropic.claude-*"
      }
    ]
  })

  tags = var.tags
}
