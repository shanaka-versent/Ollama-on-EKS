# IAM Module
# @author Shanaka Jayasundera - shanakaj@gmail.com

# EKS Cluster IAM Role
resource "aws_iam_role" "cluster" {
  name = "role-eks-cluster-${var.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = var.enable_auto_mode ? ["sts:AssumeRole", "sts:TagSession"] : ["sts:AssumeRole"]
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_vpc_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

# Auto Mode — additional managed policies for compute, storage, networking, and load balancing
resource "aws_iam_role_policy_attachment" "cluster_compute" {
  count      = var.enable_auto_mode ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSComputePolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_block_storage" {
  count      = var.enable_auto_mode ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_load_balancing" {
  count      = var.enable_auto_mode ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_networking" {
  count      = var.enable_auto_mode ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy"
  role       = aws_iam_role.cluster.name
}

# EKS Node Group IAM Role
resource "aws_iam_role" "node" {
  name = "role-eks-node-${var.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

# Auto Mode — minimal node policy + ECR pull-only (for Auto Mode managed nodes)
resource "aws_iam_role_policy_attachment" "node_minimal_policy" {
  count      = var.enable_auto_mode ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_ecr_pull_only" {
  count      = var.enable_auto_mode ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  role       = aws_iam_role.node.name
}

# EBS CSI Driver IRSA Role (for persistent volume support)
resource "aws_iam_role" "ebs_csi" {
  count = var.create_ebs_csi_role ? 1 : 0
  name  = "role-ebs-csi-driver-${var.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = var.create_ebs_csi_role ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi[0].name
}

# ==============================================================================
# GitHub Actions OIDC Federation (CI/CD for Terraform)
# ==============================================================================
# Allows GitHub Actions workflows to assume an IAM role without long-lived
# credentials. The OIDC provider trusts GitHub's token endpoint; the role
# trust policy is scoped to a specific repository.

data "tls_certificate" "github" {
  count = var.enable_github_oidc ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = var.tags
}

resource "aws_iam_role" "github_actions_terraform" {
  count = var.enable_github_oidc ? 1 : 0
  name  = "github-actions-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github[0].arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = var.tags
}

# PowerUserAccess covers all services Terraform manages (VPC, EKS, API GW,
# CloudFront, WAF, Cognito, Lambda, S3, DynamoDB, Prometheus, Grafana, etc.)
# but blocks IAM-admin-level actions (creating/deleting IAM users/policies).
# Explicit deny list below blocks services this project never uses — limits
# blast radius if the GitHub OIDC token is compromised.
resource "aws_iam_role_policy_attachment" "github_actions_power_user" {
  count      = var.enable_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
  role       = aws_iam_role.github_actions_terraform[0].name
}

# Explicit deny for AWS services this project never touches.
# Deny overrides PowerUserAccess allow — prevents lateral movement
# if the GitHub Actions OIDC token is compromised.
resource "aws_iam_role_policy" "github_actions_deny_unused" {
  count = var.enable_github_oidc ? 1 : 0
  name  = "deny-unused-services"
  role  = aws_iam_role.github_actions_terraform[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyUnusedServices"
        Effect = "Deny"
        Action = [
          "rds:*",
          "redshift:*",
          "kinesis:*",
          "sqs:*",
          "elasticache:*",
          "es:*",
          "opensearch:*",
          "kafka:*",
          "mq:*",
          "dax:*",
          "neptune:*",
          "docdb:*",
          "lightsail:*",
          "appstream:*",
          "workspaces:*",
          "chime:*",
          "connect:*",
          "pinpoint:*",
          "organizations:*",
          "account:*",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyDestructiveIAMActions"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:CreateGroup",
          "iam:DeleteGroup",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:DeactivateMFADevice",
          "iam:DeleteVirtualMFADevice",
        ]
        Resource = "*"
      },
    ]
  })
}

# Terraform needs IAM permissions for creating roles, policies, and OIDC
# providers (PowerUserAccess blocks these). Scoped to ollama-* resources only.
resource "aws_iam_role_policy" "github_actions_iam" {
  count = var.enable_github_oidc ? 1 : 0
  name  = "terraform-iam-management"
  role  = aws_iam_role.github_actions_terraform[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IAMRoleManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
          "iam:UpdateAssumeRolePolicy",
          "iam:GetRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:PassRole",
          "iam:ListInstanceProfilesForRole",
        ]
        Resource = [
          "arn:aws:iam::*:role/role-*",
          "arn:aws:iam::*:role/ollama-*",
          "arn:aws:iam::*:role/github-actions-terraform",
        ]
      },
      {
        Sid    = "IAMPolicyManagement"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:TagPolicy",
        ]
        Resource = "arn:aws:iam::*:policy/ollama-*"
      },
      {
        Sid    = "IAMOIDCProvider"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:ListOpenIDConnectProviders",
        ]
        Resource = "*"
      },
      {
        Sid    = "IAMServiceLinkedRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "iam:GetServiceLinkedRoleDeletionStatus",
        ]
        Resource = "*"
      },
    ]
  })
}
