# cert-manager Module — Automated TLS Certificate Management
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Replaces manual openssl cert generation (scripts/05-generate-certs.sh).
# Deploys cert-manager via Helm and creates a self-signed ClusterIssuer.
# Certificates for *.ollama.internal are auto-renewed (90d duration, 30d before).

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "global.leaderElection.namespace"
    value = "cert-manager"
  }

  # Air-gap: restrict network access
  set {
    name  = "webhook.networkPolicy.enabled"
    value = "true"
  }

  depends_on = [var.eks_cluster_endpoint]
}
