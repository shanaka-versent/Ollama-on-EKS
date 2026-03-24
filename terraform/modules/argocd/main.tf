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

# ── Pre-destroy cleanup: delete ArgoCD apps before EKS is destroyed ──────────
# ArgoCD-managed K8s resources (Gateway, Istio) create AWS resources (NLBs,
# security groups) via in-cluster controllers. These AWS resources are NOT in
# Terraform state. If EKS is destroyed first, the controllers die before they
# can clean up, leaving orphaned NLBs (~$16/mo) and security groups.
#
# This provisioner deletes all ArgoCD applications (which cascade-deletes K8s
# resources, triggering the controllers to clean up AWS resources) and waits
# for the NLB to be deregistered before Terraform proceeds to destroy EKS.
resource "null_resource" "argocd_cleanup" {
  depends_on = [helm_release.argocd_root_app]

  triggers = {
    cluster_name = var.cluster_name
    region       = var.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "==> Pre-destroy: cleaning up ArgoCD-managed AWS resources..."

      # Configure kubectl for this cluster
      aws eks update-kubeconfig \
        --region ${self.triggers.region} \
        --name ${self.triggers.cluster_name} 2>/dev/null || true

      # Delete all ArgoCD applications (cascades to K8s resources → AWS resources)
      kubectl delete applications -n argocd --all --timeout=120s 2>/dev/null || true

      # Wait for NLB to be cleaned up by the LB controller (up to 3 min)
      echo "  Waiting for NLB cleanup..."
      for i in $(seq 1 18); do
        NLB_COUNT=$(aws elbv2 describe-load-balancers --region ${self.triggers.region} \
          --query "LoadBalancers[?contains(LoadBalancerName, '${self.triggers.cluster_name}')] | length(@)" \
          --output text 2>/dev/null || echo "0")
        if [ "$NLB_COUNT" = "0" ]; then
          echo "  NLB cleaned up."
          break
        fi
        echo "  [$((i*10))s] NLB still exists ($NLB_COUNT remaining)..."
        sleep 10
      done

      # Delete any remaining Helm releases (observability, cert-manager, etc.)
      for ns in monitoring cert-manager; do
        helm list -n "$ns" -q 2>/dev/null | while read release; do
          echo "  Uninstalling Helm release: $release ($ns)"
          helm uninstall "$release" -n "$ns" --timeout 60s 2>/dev/null || true
        done
      done

      echo "==> Pre-destroy cleanup complete."
    EOT
  }
}
