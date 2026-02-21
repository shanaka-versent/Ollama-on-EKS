# ArgoCD Bootstrap Module
# Installs ArgoCD via Helm, then bootstraps the App-of-Apps root application
# that points to argocd/apps/ in the Git repository.
#
# All Kubernetes workloads (Istio, Ollama, NVIDIA plugin, Gateway, HTTPRoutes)
# are managed by ArgoCD from Git — not by Terraform directly.

locals {
  # Tolerations applied to all ArgoCD components so they run on system nodes
  # (which have the CriticalAddonsOnly:NoSchedule taint)
  critical_toleration = {
    key      = "CriticalAddonsOnly"
    operator = "Exists"
    effect   = "NoSchedule"
  }
}

# ── Step 1: Install ArgoCD via the official Helm chart ─────────────────────────
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = var.namespace
  create_namespace = true
  timeout          = 300

  values = [
    yamlencode({
      global = {
        # Run on system nodes (CriticalAddonsOnly taint)
        tolerations = [local.critical_toleration]
        nodeSelector = { "kubernetes.io/os" = "linux" }
      }

      server = {
        # Disable TLS on the ArgoCD server — access via port-forward or ingress
        extraArgs = ["--insecure"]
      }

      configs = {
        params = {
          # Allow ArgoCD to manage resources in all namespaces
          "application.namespaces" = "*"
        }
      }
    })
  ]
}

# ── Step 2: Bootstrap root Application (App-of-Apps pattern) ───────────────────
# The argocd-apps chart creates an ArgoCD Application that watches argocd/apps/
# in the Git repository. ArgoCD then discovers and syncs all child Application
# manifests found there, deploying them in sync-wave order.
resource "helm_release" "argocd_root_app" {
  name       = "argocd-root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.2"
  namespace  = var.namespace
  timeout    = 120

  # argocd-apps v2.x uses a map (application name as key), not a list.
  # Using a list with a `name` field causes the chart to use the numeric
  # list index as the application name, producing the "cannot unmarshal
  # number into metadata.name" error.
  values = [
    yamlencode({
      applications = {
        "ollama-root" = {
          namespace = var.namespace
          project   = "default"

          source = {
            repoURL        = var.git_repo_url
            targetRevision = "HEAD"
            path           = "argocd/apps"
          }

          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = var.namespace
          }

          syncPolicy = {
            automated = {
              prune    = true  # Remove resources deleted from Git
              selfHeal = true  # Auto-correct drift
            }
            syncOptions = [
              "CreateNamespace=true",
              "ApplyOutOfSyncOnly=true",
            ]
          }
        }
      }
    })
  ]

  depends_on = [helm_release.argocd]
}
