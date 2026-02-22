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
#   - Transit Gateway (Kong Cloud Gateway <-> EKS private connectivity)
#
# Layer 3: GitOps Bootstrap (Terraform)
#   - ArgoCD installed via Helm (runs on system nodes)
#   - Root Application bootstrapped — watches argocd/apps/ in Git
#   - ArgoCD auto-deploys in sync wave order:
#       Wave -2/-1:  Gateway API CRDs + Istio CRDs
#       Wave 0:      Istiod + Istio CNI + ztunnel + NVIDIA Device Plugin
#       Wave 1:      Namespaces (ollama, istio-ingress) with ambient mesh label
#       Wave 2:      StorageClass + PVC (200Gi EBS gp3)
#       Wave 3:      Ollama Deployment + Service + NetworkPolicy
#       Wave 4:      Model Loader Job (pulls qwen3-coder:30b)
#       Wave 5:      Istio Gateway (creates internal NLB)
#       Wave 6:      HTTPRoutes (routing to Ollama :11434)
#
# Layer 4: Kong Cloud Gateway (Scripts + decK)
#   - TLS certs for Istio Gateway (scripts/02-generate-certs.sh)
#   - Kong Konnect Cloud Gateway setup (scripts/03-setup-cloud-gateway.sh)
#   - Kong routes, plugins, consumers (scripts/04-post-setup.sh + deck/kong.yaml)
#
# Traffic Flow:
# Client --> Kong Cloud GW (Kong's infra) --[Transit GW]--> Internal NLB --> Istio Gateway --> Ollama

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
# The Istio Gateway resource (deployed by scripts/01-install-istio.sh) creates
# a Service type: LoadBalancer with internal NLB annotations. The LB Controller
# reconciles this into an AWS internal NLB that Kong Cloud Gateway reaches via
# Transit Gateway.

# LB Controller IAM Policy
resource "aws_iam_policy" "lb_controller" {
  count       = var.enable_kong ? 1 : 0
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
  count = var.enable_kong ? 1 : 0
  name  = "role-aws-lb-controller-${local.name_prefix}"

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
  count      = var.enable_kong ? 1 : 0
  policy_arn = aws_iam_policy.lb_controller[0].arn
  role       = aws_iam_role.lb_controller[0].name
}

# LB Controller Helm Release
module "lb_controller" {
  count  = var.enable_kong ? 1 : 0
  source = "./modules/lb-controller"

  cluster_name       = module.eks.cluster_name
  iam_role_arn       = aws_iam_role.lb_controller[0].arn
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  cluster_dependency = module.eks.cluster_name
}

# Wait for LB Controller to be ready before ArgoCD tries to create the NLB via Gateway
resource "time_sleep" "wait_for_lb_controller" {
  count           = var.enable_kong ? 1 : 0
  depends_on      = [module.lb_controller]
  create_duration = "60s"
}

# ==============================================================================
# TRANSIT GATEWAY -- Kong Cloud Gateway <-> EKS Private Connectivity
# ==============================================================================
# Creates an AWS Transit Gateway and shares it via RAM so Kong's Cloud Gateway
# can establish private network connectivity to the EKS VPC.
# Kong Cloud Gateway sends all traffic to the Istio Gateway NLB via this TGW.
#
# After terraform apply, ArgoCD automatically installs Istio + deploys Ollama.
# Then run: scripts/02-generate-certs.sh + scripts/03-setup-cloud-gateway.sh
# Note: auto_accept_shared_attachments is enabled — no manual acceptance needed

resource "aws_ec2_transit_gateway" "kong" {
  count       = var.enable_kong ? 1 : 0
  description = "Transit Gateway for Kong Cloud Gateway connectivity"

  amazon_side_asn                 = 64512
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-kong-tgw"
  })
}

# Attach EKS VPC to Transit Gateway
resource "aws_ec2_transit_gateway_vpc_attachment" "eks" {
  count              = var.enable_kong ? 1 : 0
  subnet_ids         = module.vpc.private_subnet_ids
  transit_gateway_id = aws_ec2_transit_gateway.kong[0].id
  vpc_id             = module.vpc.vpc_id

  dns_support = "enable"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-eks-tgw-attachment"
  })
}

# Route Kong Cloud Gateway CIDR (192.168.0.0/16) through Transit Gateway
resource "aws_route" "kong_cloud_gw" {
  count = var.enable_kong ? length(module.vpc.private_route_table_ids) : 0

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = var.kong_cloud_gateway_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.kong[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.eks]
}

# Share Transit Gateway with Kong's AWS account via RAM
resource "aws_ram_resource_share" "kong_tgw" {
  count                     = var.enable_kong ? 1 : 0
  name                      = "${local.name_prefix}-kong-tgw-share"
  allow_external_principals = true

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-kong-tgw-share"
  })
}

resource "aws_ram_resource_association" "kong_tgw" {
  count              = var.enable_kong ? 1 : 0
  resource_arn       = aws_ec2_transit_gateway.kong[0].arn
  resource_share_arn = aws_ram_resource_share.kong_tgw[0].arn
}

# Security Group rule: Allow inbound from Kong Cloud Gateway CIDR
resource "aws_security_group_rule" "allow_kong_cloud_gw" {
  count             = var.enable_kong ? 1 : 0
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [var.kong_cloud_gateway_cidr]
  security_group_id = module.eks.cluster_security_group_id
  description       = "Allow inbound from Kong Cloud Gateway via Transit Gateway"
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
