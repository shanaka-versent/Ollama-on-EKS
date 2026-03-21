# ──────────────────────────────────────────────────────────────────────
# 1. kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# ──────────────────────────────────────────────────────────────────────
resource "helm_release" "kube_prometheus_stack" {
  namespace        = "monitoring"
  create_namespace = true
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "67.4.0" # check latest

  values = [templatefile("${path.module}/values/kube-prometheus-stack.yaml", {
    grafana_admin_password        = var.grafana_admin_password
    prometheus_retention          = "${var.prometheus_retention_days}d"
    prometheus_storage_size       = var.prometheus_storage_size
    grafana_storage_size          = var.grafana_storage_size
    cluster_name                  = var.eks_cluster_name
    grafana_cloudwatch_role_arn   = aws_iam_role.grafana_cloudwatch.arn
  })]

  # Wait for CRDs to be ready before DCGM exporter creates ServiceMonitors
  wait    = true
  timeout = 600 # 10 minutes — large chart with many CRDs
}

# ──────────────────────────────────────────────────────────────────────
# 1b. IRSA Role for Grafana → CloudWatch (FinOps dashboard)
# ──────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "grafana_cloudwatch" {
  name = "${var.eks_cluster_name}-grafana-cloudwatch"

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
          "${replace(var.eks_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:monitoring:kube-prometheus-stack-grafana"
          "${replace(var.eks_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "grafana_cloudwatch" {
  name = "cloudwatch-read"
  role = aws_iam_role.grafana_cloudwatch.id

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

# ──────────────────────────────────────────────────────────────────────
# 2. NVIDIA DCGM Exporter (GPU metrics — runs on GPU nodes only)
# ──────────────────────────────────────────────────────────────────────
resource "helm_release" "dcgm_exporter" {
  namespace        = "monitoring"
  create_namespace = true
  name             = "dcgm-exporter"
  repository       = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart            = "dcgm-exporter"
  version          = "4.8.1"

  values = [templatefile("${path.module}/values/dcgm-exporter.yaml", {
    gpu_node_selector_key   = var.gpu_node_selector_key
    gpu_node_selector_value = var.gpu_node_selector_value
  })]

  # ServiceMonitor CRD comes from kube-prometheus-stack — must deploy first
  depends_on = [helm_release.kube_prometheus_stack]
}

# ──────────────────────────────────────────────────────────────────────
# 3. Grafana dashboards as ConfigMaps (air-gapped, no internet fetch)
# ──────────────────────────────────────────────────────────────────────
resource "kubernetes_config_map" "gpu_dashboard" {
  metadata {
    name      = "grafana-dashboard-gpu"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1" # Auto-discovered by Grafana sidecar
    }
  }

  data = {
    "gpu-metrics.json" = file("${path.module}/dashboards/gpu-metrics.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "ollama_dashboard" {
  metadata {
    name      = "grafana-dashboard-ollama"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "ollama-api-metrics.json" = file("${path.module}/dashboards/ollama-api-metrics.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "karpenter_dashboard" {
  metadata {
    name      = "grafana-dashboard-karpenter"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "karpenter-metrics.json" = file("${path.module}/dashboards/karpenter-metrics.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "finops_dashboard" {
  metadata {
    name      = "grafana-dashboard-finops"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "finops-showback.json" = file("${path.module}/dashboards/finops-showback.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
