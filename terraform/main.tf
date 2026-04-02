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

  # AMP remote-write role: shared AMP creates its own IRSA role, per-stack AMG has its own, or none
  amp_remote_write_role_arn = var.amp_remote_write_endpoint != "" ? aws_iam_role.shared_amp_write[0].arn : (var.enable_managed_grafana ? module.managed_grafana[0].prometheus_remote_write_role_arn : "")
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
  enable_gpu_az_c    = true
  tags               = var.tags
}

# ==============================================================================
# LAYER 2: BASE EKS CLUSTER SETUP
# ==============================================================================

# IAM Module - Cluster and Node roles
module "iam" {
  source = "./modules/iam"

  name_prefix        = local.name_prefix
  enable_auto_mode   = true
  enable_github_oidc = true
  github_repo        = "shanaka-versent/Ollama-on-EKS"
  tags               = var.tags
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
  subnet_ids = concat(module.vpc.public_subnet_ids, module.vpc.private_subnet_ids)

  # All nodes managed by Auto Mode (Karpenter) — no managed node groups needed.
  # System nodes provision automatically via built-in "system" pool.
  # GPU instances provision automatically when pods request nvidia.com/gpu.

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
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
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

  project_name                     = var.project_name
  api_gateway_endpoint             = module.api_gateway.api_endpoint
  nlb_dns_name                     = var.nlb_dns_name
  nlb_arn                          = var.nlb_arn
  allowed_ips                      = var.waf_allowed_ips
  rate_limit                       = var.waf_rate_limit
  geo_countries                    = var.waf_geo_countries
  enable_bot_control               = var.waf_enable_bot_control
  enable_origin_lockdown           = var.enable_origin_lockdown
  origin_verify_secret             = var.enable_origin_lockdown ? random_password.origin_verify_secret[0].result : ""
  api_key_value                    = module.api_gateway.api_key_value
  enable_portal                    = var.cloudfront_domain != ""
  portal_s3_bucket_regional_domain = var.cloudfront_domain != "" ? module.api_key_portal.s3_bucket_regional_domain : ""
  portal_oac_id                    = var.cloudfront_domain != "" ? module.api_key_portal.oac_id : ""
  enable_login                     = var.cloudfront_domain != ""
  login_s3_bucket_regional_domain  = var.cloudfront_domain != "" ? module.api_key_portal.login_s3_bucket_regional_domain : ""
  login_oac_id                     = var.cloudfront_domain != "" ? module.api_key_portal.login_oac_id : ""
  tags                             = var.tags
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
# OBSERVABILITY (Prometheus + DCGM Exporter → AMP → AWS Managed Grafana)
# ==============================================================================
# Prometheus + DCGM Exporter run in-cluster, remote-write to AMP.
# AWS Managed Grafana (AMG) reads from AMP + CloudWatch natively.
# No in-cluster Grafana — all dashboards in AMG via IAM Identity Center SSO.

module "observability" {
  source = "./modules/observability"

  eks_cluster_name          = module.eks.cluster_name
  prometheus_retention_days = var.prometheus_retention_days
  prometheus_storage_size   = var.prometheus_storage_size
  eks_oidc_provider_arn     = module.eks.oidc_provider_arn
  eks_oidc_issuer_url       = module.eks.oidc_issuer_url

  # AMP integration: Prometheus remote-writes metrics to AMP
  # Priority: 1) shared AMP endpoint (from shared-infra), 2) per-stack AMG, 3) none (in-cluster only)
  amp_remote_write_endpoint = var.amp_remote_write_endpoint != "" ? var.amp_remote_write_endpoint : (var.enable_managed_grafana ? module.managed_grafana[0].amp_remote_write_endpoint : "")
  amp_remote_write_role_arn = local.amp_remote_write_role_arn

  # Alert notifications: Alertmanager → SNS → email
  alert_email = var.alert_email

  tags = var.tags

  depends_on = [
    module.eks,
    aws_eks_addon.ebs_csi,
    module.argocd,
  ]
}

# ==============================================================================
# SHARED AMP — IRSA role for Prometheus remote-write (when using shared-infra AMP)
# ==============================================================================
# When amp_remote_write_endpoint is set (from shared-infra), this stack needs
# its own IRSA role because the role trust policy references the stack's OIDC provider.

resource "aws_iam_role" "shared_amp_write" {
  count = var.amp_remote_write_endpoint != "" ? 1 : 0
  name  = "${var.project_name}-${var.environment}-amp-write"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(module.eks.oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:monitoring:kube-prometheus-stack-prometheus"
          "${replace(module.eks.oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "shared_amp_write" {
  count = var.amp_remote_write_endpoint != "" ? 1 : 0
  name  = "amp-remote-write"
  role  = aws_iam_role.shared_amp_write[0].id

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
      Resource = "*"
    }]
  })
}

# ==============================================================================
# AWS MANAGED GRAFANA (AMG + AMP — SSO via IAM Identity Center)
# ==============================================================================
# Disabled by default ($9/editor/month). Uses in-cluster Grafana instead.
# To re-enable AMG: set enable_managed_grafana = true in terraform.tfvars

module "managed_grafana" {
  source = "./modules/managed-grafana"
  count  = var.enable_managed_grafana ? 1 : 0

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

# Wait for open-webui namespace to exist (created by ArgoCD wave 1).
# Terraform can't create it because ArgoCD may have already created it,
# and kubernetes_namespace fails with "already exists" on re-apply.
resource "null_resource" "wait_for_open_webui_ns" {
  provisioner "local-exec" {
    command = <<-EOT
      for i in $(seq 1 60); do
        kubectl get namespace open-webui >/dev/null 2>&1 && exit 0
        echo "Waiting for open-webui namespace... ($i/60)"
        sleep 5
      done
      echo "WARNING: open-webui namespace not found after 5 min — creating it"
      kubectl create namespace open-webui --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    EOT
  }

  depends_on = [module.argocd]
}

# Kubernetes Secret for Open WebUI OAuth credentials
resource "kubernetes_secret" "webui_oauth" {
  metadata {
    name      = "webui-oauth-cognito"
    namespace = "open-webui"
  }

  data = {
    OAUTH_CLIENT_ID     = module.cognito.client_id
    OAUTH_CLIENT_SECRET = module.cognito.client_secret
    OPENID_PROVIDER_URL = module.cognito.openid_config_url
    OAUTH_LOGOUT_URL    = module.cognito.logout_url
    # CloudFront domain — injected so Open WebUI uses the correct external URL
    # for OAuth redirect_uri without hardcoding in K8s manifests
    CLOUDFRONT_DOMAIN = module.cdn_waf.cloudfront_domain
    # Banner timestamp must be Unix epoch (number), not a date string
    # HTML content with styled button links for better visibility
    WEBUI_BANNERS = jsonencode([
      {
        id          = "api-key-portal"
        type        = "info"
        title       = ""
        content     = "<div style='display:flex;align-items:center;gap:12px;padding:4px 0'><span style='font-size:14px'>Need CLI or API access?</span><a href='/portal/' style='display:inline-block;background:#fff;color:#1e40af;font-weight:600;padding:6px 16px;border-radius:6px;text-decoration:none;font-size:13px;box-shadow:0 1px 3px rgba(0,0,0,0.2);transition:all 0.2s'>Generate API Key</a></div>"
        dismissible = true
        timestamp   = 1774051200
      },
      {
        id          = "change-password"
        type        = "info"
        title       = ""
        content     = "<div style='display:flex;align-items:center;gap:12px;padding:4px 0'><span style='font-size:14px'>Need to reset your password?</span><a href='/auth/login.html' style='display:inline-block;background:#fff;color:#1e40af;font-weight:600;padding:6px 16px;border-radius:6px;text-decoration:none;font-size:13px;box-shadow:0 1px 3px rgba(0,0,0,0.2);transition:all 0.2s'>Reset Password</a></div>"
        dismissible = true
        timestamp   = 1774051200
      }
    ])
  }

  depends_on = [null_resource.wait_for_open_webui_ns, module.cognito, module.argocd]
}

# ==============================================================================
# API KEY PORTAL (Self-Service Key Management)
# ==============================================================================
# Users generate and manage their own API Gateway keys via a static portal.
# Uses the existing Cognito User Pool for auth (separate SPA app client).

module "api_key_portal" {
  source = "./modules/api-key-portal"

  project_name              = var.project_name
  region                    = var.region
  cognito_user_pool_id      = module.cognito.user_pool_id
  cognito_user_pool_arn     = module.cognito.user_pool_arn
  cognito_domain            = module.cognito.cognito_domain
  cloudfront_domain         = module.cdn_waf.cloudfront_domain
  signup_client_id          = module.cognito.signup_client_id
  cognito_client_id         = module.cognito.client_id
  cognito_client_secret     = module.cognito.client_secret
  rest_api_id               = module.api_gateway.api_id
  rest_api_root_resource_id = module.api_gateway.root_resource_id
  rest_api_execution_arn    = module.api_gateway.api_execution_arn
  usage_plan_id             = module.api_gateway.usage_plan_id
  api_deployment_trigger    = module.api_gateway.deployment_trigger_hash
  eks_cluster_name          = module.eks.cluster_name
  tags                      = var.tags

  # Note: depends_on removed — variable references create implicit dependencies.
  # Explicit depends_on defers ALL data sources in the module to apply time,
  # which causes aws_caller_identity to be (known after apply) and forces
  # S3 bucket replacement on every plan.
}

# EKS access entry for GPU controller Lambda — allows it to patch
# deployments and ScaledObjects in the ollama namespace
resource "aws_eks_access_entry" "gpu_controller" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.api_key_portal.gpu_controller_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "gpu_controller" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.api_key_portal.gpu_controller_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["ollama"]
  }

  depends_on = [aws_eks_access_entry.gpu_controller]
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

  project_name          = var.project_name
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  private_subnet_cidrs  = module.vpc.private_subnet_cidrs
  eks_oidc_provider_arn = module.eks.oidc_provider_arn
  tags                  = var.tags
}

data "aws_caller_identity" "current" {}

# ==============================================================================
# CLOUDTRAIL — API audit trail (High Finding #13)
# ==============================================================================
# Single-region trail for management events. Free for first trail.
# S3 storage: ~$2/mo. Enables investigation of who created/deleted resources.

resource "aws_cloudtrail" "main" {
  name                       = "${var.project_name}-trail"
  s3_bucket_name             = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail      = false
  enable_log_file_validation = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
  tags       = var.tags
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project_name}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
    ]
  })
}

# ==============================================================================
# CLOUDWATCH ALARMS — Proactive incident detection (High Finding #6)
# ==============================================================================

resource "aws_cloudwatch_metric_alarm" "apigw_5xx" {
  alarm_name          = "${var.project_name}-apigw-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "API Gateway 5xx errors exceeded threshold"
  alarm_actions       = [module.observability.sns_topic_arn]
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "cf_error_rate" {
  alarm_name          = "${var.project_name}-cf-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "5xxErrorRate"
  namespace           = "AWS/CloudFront"
  period              = 300
  statistic           = "Average"
  threshold           = 5
  alarm_description   = "CloudFront 5xx error rate exceeded 5%"
  alarm_actions       = [module.observability.sns_topic_arn]
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}
