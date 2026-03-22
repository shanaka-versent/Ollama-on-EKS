# Ollama on EKS - Main Terraform Configuration
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Architecture Layers:
# ===================
# Layer 1: Cloud Foundations (Terraform)
#   - VPC, Subnets, NAT Gateway, Internet Gateway
#
# Layer 2: Base EKS Cluster Setup (Terraform)
#   - IAM Roles (Cluster, Node, EBS CSI, LB Controller)
#   - EKS Cluster, Node Groups (System + GPU)
#   - OIDC Provider for IRSA
#   - EKS Addons (VPC-CNI, CoreDNS, kube-proxy, EBS CSI)
#   - AWS Load Balancer Controller (creates internal NLB from Gateway API resources)
#
# Layer 3: GitOps Bootstrap (Terraform)
#   - ArgoCD installed via Helm (runs on system nodes)
#   - Root Application bootstrapped — watches argocd/apps/ in Git
#   - ArgoCD auto-deploys in sync wave order:
#       Wave -2/-1:  Gateway API CRDs + Istio CRDs
#       Wave 0:      Istiod + Istio CNI + ztunnel + NVIDIA Device Plugin
#       Wave 1:      Namespaces (ollama, istio-system) with ambient mesh label
#       Wave 2:      StorageClass + PVC (200Gi EBS gp3)
#       Wave 3:      Ollama Deployment + Service + NetworkPolicy
#       Wave 4:      Model Loader Job (pulls qwen3.5:122b-a10b)
#       Wave 5:      Istio Gateway (creates internal NLB)
#       Wave 6:      HTTPRoutes (routing to Ollama :11434)
#
# Layer 4: CloudFront + WAF + API Gateway (Terraform)
#   - API Gateway (HTTP API) → VPC Link → Internal NLB → Istio Gateway → Ollama
#   - CloudFront (HTTPS only, cache disabled for POST)
#   - WAFv2 (rate limit, IP allowlist, geo-block, SQL/XSS, optional bot control)
#   - cert-manager for automated TLS certificate management
#
# Traffic Flow:
# Client → CloudFront (WAF) → API Gateway (HTTP API) → VPC Link → NLB → Istio → Ollama

locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  cluster_name = "eks-${local.name_prefix}"
}

# ==============================================================================
# LAYER 1: CLOUD FOUNDATIONS
# ==============================================================================

module "vpc" {
  source = "./modules/vpc"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  cluster_name       = local.cluster_name
  enable_nat_gateway = var.enable_nat_gateway
  tags               = var.tags
}

# ==============================================================================
# LAYER 2: BASE EKS CLUSTER SETUP
# ==============================================================================

# IAM Module - Cluster and Node roles
module "iam" {
  source = "./modules/iam"

  name_prefix = local.name_prefix
  tags        = var.tags
}

# EKS Module - Kubernetes cluster with System + GPU node groups
module "eks" {
  source = "./modules/eks"

  name_prefix        = local.name_prefix
  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version
  cluster_role_arn   = module.iam.cluster_role_arn
  node_role_arn      = module.iam.node_role_arn

  # Network
  subnet_ids      = concat(module.vpc.public_subnet_ids, module.vpc.private_subnet_ids)
  node_subnet_ids = module.vpc.private_subnet_ids
  # Pin GPU nodes to the first private subnet (AZ-a) so they always land in the
  # same AZ as the EBS PVC. EBS volumes are AZ-scoped — a GPU node in a different
  # AZ causes a volume affinity conflict and the Ollama pod stays Pending.
  gpu_subnet_ids  = [module.vpc.private_subnet_ids[0]]

  # System Node Pool
  system_node_count         = var.system_node_count
  system_node_instance_type = var.system_node_instance_type
  system_node_min_count     = var.system_node_min_count
  system_node_max_count     = var.system_node_max_count

  # GPU Node Pool
  enable_gpu_node_pool   = var.enable_gpu_node_pool
  gpu_node_count         = var.gpu_node_count
  gpu_node_instance_type = var.gpu_node_instance_type
  gpu_node_disk_size     = var.gpu_node_disk_size
  gpu_node_min_count     = var.gpu_node_min_count
  gpu_node_max_count     = var.gpu_node_max_count
  gpu_capacity_type      = var.gpu_capacity_type

  # Logging
  enable_logging = var.enable_logging

  tags = var.tags
}

# IAM for EBS CSI Driver (IRSA - needs OIDC from EKS cluster)
module "iam_ebs_csi" {
  source = "./modules/iam"

  name_prefix         = "${local.name_prefix}-ebs-csi"
  create_ebs_csi_role = true
  oidc_provider_arn   = module.eks.oidc_provider_arn
  oidc_provider_url   = module.eks.oidc_provider_url
  tags                = var.tags
}

# EBS CSI Driver Addon (installed after EKS + IRSA role are ready)
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.iam_ebs_csi.ebs_csi_role_arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

# ==============================================================================
# AWS LOAD BALANCER CONTROLLER (creates internal NLB for Istio Gateway)
# ==============================================================================
# The Istio Gateway resource creates a Service type: LoadBalancer with internal
# NLB annotations. The LB Controller reconciles this into an AWS internal NLB
# that API Gateway reaches via VPC Link.

# LB Controller IAM Policy
resource "aws_iam_policy" "lb_controller" {
  name        = "policy-aws-lb-controller-${local.name_prefix}"
  description = "IAM policy for AWS Load Balancer Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes", "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones", "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs", "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags", "ec2:GetCoipPoolUsage", "ec2:DescribeCoipPools",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates", "acm:DescribeCertificate",
          "iam:ListServerCertificates", "iam:GetServerCertificate",
          "waf-regional:GetWebACL", "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL", "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL", "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState", "shield:DescribeProtection",
          "shield:CreateProtection", "shield:DeleteProtection"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = { "ec2:CreateAction" = "CreateSecurityGroup" }
          Null         = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress", "ec2:DeleteSecurityGroup"]
        Resource = "*"
        Condition = {
          Null = { "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup"]
        Resource = "*"
        Condition = {
          Null = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:CreateListener", "elasticloadbalancing:DeleteListener", "elasticloadbalancing:CreateRule", "elasticloadbalancing:DeleteRule"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup"
        ]
        Resource = "*"
        Condition = {
          Null = { "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          StringEquals = {
            "elasticloadbalancing:CreateAction" = ["CreateTargetGroup", "CreateLoadBalancer"]
          }
          Null = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

# LB Controller IRSA Role
resource "aws_iam_role" "lb_controller" {
  name = "role-aws-lb-controller-${local.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${module.eks.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  policy_arn = aws_iam_policy.lb_controller.arn
  role       = aws_iam_role.lb_controller.name
}

# LB Controller Helm Release
module "lb_controller" {
  source = "./modules/lb-controller"

  cluster_name       = module.eks.cluster_name
  iam_role_arn       = aws_iam_role.lb_controller.arn
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  cluster_dependency = module.eks.cluster_name
}

# Wait for LB Controller to be ready before ArgoCD tries to create the NLB via Gateway
resource "time_sleep" "wait_for_lb_controller" {
  depends_on      = [module.lb_controller]
  create_duration = "60s"
}

# ==============================================================================
# LAYER 3: ARGOCD GITOPS BOOTSTRAP
# ==============================================================================
# ArgoCD is installed via Helm and a root Application is bootstrapped that
# watches argocd/apps/ in the Git repository. ArgoCD then automatically
# deploys all Kubernetes workloads (Istio, Ollama, Gateway, HTTPRoutes)
# in sync-wave order — no manual kubectl apply steps needed.

module "argocd" {
  source = "./modules/argocd"

  cluster_name         = module.eks.cluster_name
  region               = var.region
  git_repo_url         = var.git_repo_url
  argocd_chart_version = var.argocd_chart_version

  depends_on = [
    module.eks,
    aws_eks_addon.ebs_csi,
    time_sleep.wait_for_lb_controller,
  ]
}

# ==============================================================================
# LAYER 4: CLOUDFRONT + WAF + API GATEWAY
# ==============================================================================
# Replaces Kong Cloud Gateway — 99% cost reduction ($756/mo → $6/mo).
# Client → CloudFront (WAF) → API Gateway → VPC Link → NLB → Istio → Ollama

# us-east-1 provider for WAFv2 (CloudFront scope requires us-east-1)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# Origin lockdown secret — auto-generated, shared between CloudFront and API Gateway.
# CloudFront sends this as the Referer header; API Gateway resource policy validates it.
resource "random_password" "origin_verify_secret" {
  count   = var.enable_origin_lockdown ? 1 : 0
  length  = 64
  special = false
}

module "api_gateway" {
  source = "./modules/api-gateway"

  project_name           = var.project_name
  nlb_arn                = var.nlb_arn
  nlb_dns_name           = var.nlb_dns_name
  api_key_required       = var.api_key_required
  throttle_rate          = var.throttle_rate
  throttle_burst         = var.throttle_burst
  enable_origin_lockdown = var.enable_origin_lockdown
  origin_verify_secret   = var.enable_origin_lockdown ? random_password.origin_verify_secret[0].result : ""
  tags                   = var.tags
}

module "cdn_waf" {
  source = "./modules/cdn-waf"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name           = var.project_name
  api_gateway_endpoint   = module.api_gateway.api_endpoint
  nlb_dns_name           = var.nlb_dns_name
  nlb_arn                = var.nlb_arn
  allowed_ips            = var.waf_allowed_ips
  rate_limit             = var.waf_rate_limit
  geo_countries          = var.waf_geo_countries
  enable_bot_control     = var.waf_enable_bot_control
  enable_origin_lockdown = var.enable_origin_lockdown
  origin_verify_secret   = var.enable_origin_lockdown ? random_password.origin_verify_secret[0].result : ""
  tags                   = var.tags
}

# ==============================================================================
# CERT-MANAGER (Automated TLS — replaces manual openssl certs)
# ==============================================================================

module "cert_manager" {
  source = "./modules/cert-manager"

  eks_cluster_endpoint = module.eks.cluster_endpoint

  depends_on = [
    module.eks,
    module.argocd,
  ]
}

# ==============================================================================
# OBSERVABILITY (Prometheus + Grafana + DCGM Exporter)
# ==============================================================================
# Self-managed, air-gapped — no AWS managed services (AMP/AMG).
# GPU metrics stay in-cluster alongside the workloads they monitor.

module "observability" {
  source = "./modules/observability"

  eks_cluster_name         = module.eks.cluster_name
  grafana_admin_password   = var.grafana_admin_password
  prometheus_retention_days = var.prometheus_retention_days
  prometheus_storage_size   = var.prometheus_storage_size
  grafana_storage_size      = var.grafana_storage_size
  eks_oidc_provider_arn    = module.eks.oidc_provider_arn
  eks_oidc_issuer_url      = module.eks.oidc_issuer_url
  enable_grafana            = true  # Temporarily enabled alongside AMG until SSO access is resolved
  grafana_oauth_secret_name = "grafana-oauth-cognito"  # Cognito OAuth via GF_ env vars

  # AMP integration: when managed Grafana is enabled, Prometheus remote-writes to AMP
  amp_remote_write_endpoint = var.enable_managed_grafana ? module.managed_grafana[0].amp_remote_write_endpoint : ""
  amp_remote_write_role_arn = var.enable_managed_grafana ? module.managed_grafana[0].prometheus_remote_write_role_arn : ""

  tags = var.tags

  depends_on = [
    module.eks,
    aws_eks_addon.ebs_csi,
    module.argocd,
  ]
}

# ==============================================================================
# MANAGED GRAFANA (Optional — replaces in-cluster Grafana with AWS AMG + AMP)
# ==============================================================================
# Enable with: terraform apply -var="enable_managed_grafana=true"
# Prerequisites: IAM Identity Center (AWS SSO) must be enabled in the account.
# When enabled, in-cluster Grafana should be disabled in kube-prometheus-stack values.

module "managed_grafana" {
  count  = var.enable_managed_grafana ? 1 : 0
  source = "./modules/managed-grafana"

  project_name          = var.project_name
  eks_oidc_provider_arn = module.eks.oidc_provider_arn
  eks_oidc_issuer_url   = module.eks.oidc_issuer_url
  admin_user_ids        = var.grafana_admin_user_ids
  viewer_group_ids      = var.grafana_viewer_group_ids
  tags                  = var.tags

  depends_on = [module.eks]
}

# ==============================================================================
# COGNITO AUTHENTICATION (Open WebUI — MFA + OAuth)
# ==============================================================================
# Centralized auth for Open WebUI: Cognito handles signup, login, MFA.
# Users self-register, admin approves by adding to Cognito group.
# Roles (admin/user) mapped from Cognito groups to Open WebUI roles.

module "cognito" {
  source = "./modules/cognito"

  project_name       = var.project_name
  cloudfront_domain  = module.cdn_waf.cloudfront_domain
  admin_email        = var.cognito_admin_email
  notification_email = var.cognito_notification_email
  tags               = var.tags
}

# Kubernetes Secret for Open WebUI OAuth credentials
resource "kubernetes_secret" "webui_oauth" {
  metadata {
    name      = "webui-oauth-cognito"
    namespace = "open-webui"
  }

  data = {
    OAUTH_CLIENT_ID       = module.cognito.client_id
    OAUTH_CLIENT_SECRET   = module.cognito.client_secret
    OPENID_PROVIDER_URL   = module.cognito.openid_config_url
  }

  depends_on = [module.cognito]
}

# ==============================================================================
# COGNITO AUTHENTICATION (Grafana — MFA + OAuth)
# ==============================================================================
# TEMPORARY: Separate Cognito User Pool for in-cluster Grafana.
# Once AMG (AWS Managed Grafana) SSO access is resolved, disable in-cluster
# Grafana and remove this module + secret.

module "grafana_cognito" {
  source = "./modules/grafana-cognito"

  project_name       = var.project_name
  cloudfront_domain  = module.cdn_waf.cloudfront_domain
  admin_email        = var.cognito_admin_email
  notification_email = var.cognito_notification_email
  tags               = var.tags
}

# Kubernetes Secret for Grafana OAuth — uses GF_ env var convention
# Grafana auto-applies env vars matching the GF_<SECTION>_<KEY> pattern
resource "kubernetes_secret" "grafana_oauth" {
  metadata {
    name      = "grafana-oauth-cognito"
    namespace = "monitoring"
  }

  data = {
    GF_SERVER_ROOT_URL                           = "https://${module.cdn_waf.cloudfront_domain}/grafana/"
    GF_SERVER_SERVE_FROM_SUB_PATH                = "true"
    GF_AUTH_DISABLE_LOGIN_FORM                   = "true"
    GF_AUTH_GENERIC_OAUTH_ENABLED                = "true"
    GF_AUTH_GENERIC_OAUTH_NAME                   = "Request Access"
    GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP          = "true"
    GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN             = "true"
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID              = module.grafana_cognito.client_id
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET          = module.grafana_cognito.client_secret
    GF_AUTH_GENERIC_OAUTH_SCOPES                 = "openid email profile"
    GF_AUTH_GENERIC_OAUTH_AUTH_URL               = module.grafana_cognito.auth_url
    GF_AUTH_GENERIC_OAUTH_TOKEN_URL              = module.grafana_cognito.token_url
    GF_AUTH_GENERIC_OAUTH_API_URL                = module.grafana_cognito.userinfo_url
    GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH    = "contains(\"cognito:groups\" || `[]`, 'admin') && 'Admin' || 'Viewer'"
  }

  depends_on = [module.grafana_cognito]
}

# ==============================================================================
# BEDROCK INTEGRATION (Stack B — Hybrid Mode Only)
# ==============================================================================
# Deploy with: terraform apply -var="enable_bedrock=true"
# Stack A (air-gapped): set enable_bedrock=false (default)
# Stack B (hybrid):     set enable_bedrock=true

module "bedrock_integration" {
  count  = var.enable_bedrock ? 1 : 0
  source = "./modules/bedrock-integration"

  project_name         = var.project_name
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  private_subnet_cidrs = module.vpc.private_subnet_cidrs
  eks_oidc_provider_arn = module.eks.oidc_provider_arn
  tags                 = var.tags
}
