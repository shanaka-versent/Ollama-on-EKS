# Ollama Module - Kubernetes Deployment
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Deploys Ollama LLM server on EKS with GPU support:
#   - Namespace
#   - GP3 StorageClass
#   - PersistentVolumeClaim (model storage)
#   - Deployment (GPU-accelerated)
#   - Service (ClusterIP — internal only)
#   - NetworkPolicy (locked down)
#   - NVIDIA Device Plugin (DaemonSet)
#   - Model Loader Job (auto-pulls models)

# ==============================================================================
# NAMESPACE
# ==============================================================================

resource "kubernetes_namespace" "ollama" {
  metadata {
    name = var.namespace

    labels = {
      app     = "ollama"
      purpose = "private-llm"
    }
  }
}

# ==============================================================================
# GP3 STORAGE CLASS
# ==============================================================================

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type       = "gp3"
    iops       = "4000"
    throughput = "250"
  }
}

# ==============================================================================
# PERSISTENT VOLUME CLAIM (Model Storage)
# ==============================================================================

resource "kubernetes_persistent_volume_claim" "ollama_models" {
  metadata {
    name      = "ollama-models-pvc"
    namespace = kubernetes_namespace.ollama.metadata[0].name
  }

  # Don't wait for bind — gp3 uses WaitForFirstConsumer,
  # so the PVC stays Pending until the Ollama pod is scheduled
  wait_until_bound = false

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class.gp3.metadata[0].name

    resources {
      requests = {
        storage = var.model_storage_size
      }
    }
  }
}

# ==============================================================================
# NVIDIA DEVICE PLUGIN (enables GPU scheduling in K8s)
# ==============================================================================

resource "helm_release" "nvidia_device_plugin" {
  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = var.nvidia_plugin_version
  namespace  = "kube-system"

  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
}

# ==============================================================================
# OLLAMA DEPLOYMENT
# ==============================================================================

resource "kubernetes_deployment" "ollama" {
  metadata {
    name      = "ollama"
    namespace = kubernetes_namespace.ollama.metadata[0].name

    labels = {
      app = "ollama"
    }
  }

  spec {
    replicas = var.ollama_replicas

    selector {
      match_labels = {
        app = "ollama"
      }
    }

    template {
      metadata {
        labels = {
          app = "ollama"
        }
      }

      spec {
        # Schedule on GPU nodes
        node_selector = {
          "nvidia.com/gpu.present" = "true"
        }

        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name  = "ollama"
          image = "ollama/ollama:${var.ollama_image_tag}"

          port {
            container_port = 11434
            name           = "http"
            protocol       = "TCP"
          }

          env {
            name  = "OLLAMA_HOST"
            value = "0.0.0.0:11434"
          }
          env {
            name  = "OLLAMA_KEEP_ALIVE"
            value = var.ollama_keep_alive
          }
          env {
            name  = "OLLAMA_NUM_PARALLEL"
            value = tostring(var.ollama_num_parallel)
          }
          env {
            name  = "OLLAMA_MAX_LOADED_MODELS"
            value = tostring(var.ollama_max_loaded_models)
          }

          resources {
            limits = {
              "nvidia.com/gpu" = tostring(var.gpu_count)
              memory           = var.ollama_memory_limit
              cpu              = tostring(var.ollama_cpu_limit)
            }
            requests = {
              "nvidia.com/gpu" = tostring(var.gpu_count)
              memory           = var.ollama_memory_request
              cpu              = tostring(var.ollama_cpu_request)
            }
          }

          volume_mount {
            name       = "ollama-data"
            mount_path = "/root/.ollama"
          }

          readiness_probe {
            http_get {
              path = "/api/tags"
              port = 11434
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/api/tags"
              port = 11434
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }

        volume {
          name = "ollama-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ollama_models.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [helm_release.nvidia_device_plugin]
}

# ==============================================================================
# SERVICE (ClusterIP — NOT exposed to internet)
# ==============================================================================

resource "kubernetes_service" "ollama" {
  metadata {
    name      = "ollama"
    namespace = kubernetes_namespace.ollama.metadata[0].name

    labels = {
      app = "ollama"
    }
  }

  spec {
    type = "ClusterIP"

    port {
      port        = 11434
      target_port = 11434
      protocol    = "TCP"
      name        = "http"
    }

    selector = {
      app = "ollama"
    }
  }
}

# ==============================================================================
# NETWORK POLICY (locked down — istio-ingress + ollama namespaces only)
# ==============================================================================

resource "kubernetes_network_policy" "ollama_restrict" {
  metadata {
    name      = "ollama-restrict"
    namespace = kubernetes_namespace.ollama.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "ollama"
      }
    }

    policy_types = ["Ingress", "Egress"]

    # Ingress: from Istio ingress gateway (Kong traffic arrives here via NLB)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "istio-ingress"
          }
        }
      }
      ports {
        port     = "11434"
        protocol = "TCP"
      }
    }

    # Ingress: from ollama namespace itself (model loader job, health checks)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.namespace
          }
        }
      }
      ports {
        port     = "11434"
        protocol = "TCP"
      }
    }

    # Egress: DNS
    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }

    # Egress: HTTPS (for pulling models from ollama registry)
    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# ==============================================================================
# MODEL LOADER JOB (auto-pulls models after deployment)
# ==============================================================================

resource "kubernetes_job" "model_loader" {
  count = var.auto_pull_model ? 1 : 0

  metadata {
    name      = "ollama-model-loader"
    namespace = kubernetes_namespace.ollama.metadata[0].name
  }

  # Don't wait — model pull takes 10-20 min for large models
  # Monitor with: kubectl logs -f job/ollama-model-loader -n ollama
  wait_for_completion = false

  spec {
    template {
      metadata {}

      spec {
        restart_policy = "OnFailure"

        # Tolerate system node taint — this is a lightweight curl job,
        # it doesn't need GPU, just network access to the Ollama service
        toleration {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name  = "model-loader"
          image = "curlimages/curl:latest"

          command = ["/bin/sh", "-c", <<-EOT
            echo "Waiting for Ollama to be ready..."
            until curl -s http://ollama.${var.namespace}.svc:11434/api/tags; do
              sleep 5
            done
            echo "Pulling ${var.ollama_model}..."
            curl -X POST http://ollama.${var.namespace}.svc:11434/api/pull \
              -d '{"name": "${var.ollama_model}"}' \
              --max-time 3600
            echo "Model pull complete."
            curl -s http://ollama.${var.namespace}.svc:11434/api/tags
          EOT
          ]
        }
      }
    }

    backoff_limit = 3
  }

  depends_on = [
    kubernetes_deployment.ollama,
    kubernetes_service.ollama
  ]
}
