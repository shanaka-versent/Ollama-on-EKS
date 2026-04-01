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
    prometheus_retention          = "${var.prometheus_retention_days}d"
    prometheus_storage_size       = var.prometheus_storage_size
    cluster_name                  = var.eks_cluster_name
    amp_remote_write_endpoint     = var.amp_remote_write_endpoint
    amp_remote_write_role_arn     = var.amp_remote_write_role_arn
    sns_alert_topic_arn           = var.alert_email != "" ? aws_sns_topic.alerts[0].arn : ""
    alertmanager_sns_role_arn     = var.alert_email != "" ? aws_iam_role.alertmanager_sns[0].arn : ""
  })]

  # Don't wait for pods — saves ~10 min on fresh clusters.
  # Prometheus/Alertmanager pods start in background; they'll be ready
  # by the time ArgoCD finishes deploying Ollama + Gateway.
  # deploy.sh self-healing handles orphaned releases on retry.
  wait             = false
  timeout          = 300
  replace          = true
  force_update     = true
  cleanup_on_fail  = true
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
# 4. SNS Topic for Alert Notifications (email)
#    Alertmanager → SNS → Email for spot failures, cost warnings, etc.
# ──────────────────────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  count             = var.alert_email != "" ? 1 : 0
  name              = "${var.eks_cluster_name}-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "alert_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# IRSA role for Alertmanager → SNS publish
resource "aws_iam_role" "alertmanager_sns" {
  count = var.alert_email != "" ? 1 : 0
  name  = "${var.eks_cluster_name}-alertmanager-sns"

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
          "${replace(var.eks_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:monitoring:kube-prometheus-stack-alertmanager"
          "${replace(var.eks_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "alertmanager_sns" {
  count = var.alert_email != "" ? 1 : 0
  name  = "sns-publish"
  role  = aws_iam_role.alertmanager_sns[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = aws_sns_topic.alerts[0].arn
    }]
  })
}

# Dashboards are imported into shared AMG via setup-amg.sh (not in-cluster ConfigMaps).
# Dashboard JSON files in dashboards/ directory are used by setup-amg.sh.
