#!/bin/bash
# Post-Terraform Setup — Master Orchestrator
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Runs all post-terraform steps in sequence after `terraform apply`:
#   1. Configure kubectl from Terraform outputs
#   2. Wait for ArgoCD to sync Wave 1 (namespaces created)
#   3. Generate TLS certificates + create K8s secret (unblocks Wave 5)
#   4. Wait for Ollama to be ready (Wave 3)
#   5. Set up Kong Konnect Cloud AI Gateway (if .env credentials are set)
#   6. Discover NLB + sync Kong config (if Kong enabled)
#
# Usage:
#   ./scripts/01-setup.sh
#
# Prerequisites:
#   - terraform apply completed successfully
#   - .env file exists (with optional KONNECT_REGION + KONNECT_TOKEN for Kong)
#   - awscli, kubectl, helm installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"
ENV_FILE="${REPO_DIR}/.env"

# Load .env if it exists
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step()  {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ==============================================================================
# Step 1: Configure kubectl from Terraform outputs
# ==============================================================================
configure_kubectl() {
    step "Step 1: Configuring kubectl"

    if [[ ! -d "${TERRAFORM_DIR}/.terraform" ]]; then
        error "Terraform not initialized in ${TERRAFORM_DIR}"
        error "Run: cd terraform && terraform init && terraform apply"
        exit 1
    fi

    EKS_CLUSTER_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw eks_cluster_name 2>/dev/null || echo "")
    AWS_REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw region 2>/dev/null || echo "us-west-2")

    if [[ -z "$EKS_CLUSTER_NAME" ]]; then
        error "Could not read eks_cluster_name from Terraform outputs."
        error "Is the cluster fully deployed? Check: terraform -chdir=terraform output"
        exit 1
    fi

    log "Cluster: ${EKS_CLUSTER_NAME}  Region: ${AWS_REGION}"
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
    log "kubectl configured successfully"
}

# ==============================================================================
# Step 2: Wait for ArgoCD Wave 1 — namespaces to be created
# ==============================================================================
wait_for_namespaces() {
    step "Step 2: Waiting for ArgoCD Wave 1 — namespaces (ollama, istio-ingress)"

    log "ArgoCD syncs in waves. Wave 1 creates namespaces (~5-10 min after terraform apply)."
    log "Watching for: istio-ingress + ollama"

    local max_wait=900  # 15 min
    local interval=15
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        local istio_ns ollama_ns
        istio_ns=$(kubectl get namespace istio-ingress --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ollama_ns=$(kubectl get namespace ollama --no-headers 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$istio_ns" -ge 1 && "$ollama_ns" -ge 1 ]]; then
            log "Both namespaces are ready"
            # Check ArgoCD app status for visibility
            echo ""
            kubectl get applications -n argocd 2>/dev/null || true
            return
        fi

        echo -n "  [${waited}s] Waiting for namespaces"
        if [[ "$istio_ns" -lt 1 ]]; then echo -n " (istio-ingress missing)"; fi
        if [[ "$ollama_ns" -lt 1 ]]; then echo -n " (ollama missing)"; fi
        echo ""
        sleep "$interval"
        waited=$((waited + interval))
    done

    error "Namespaces not ready after ${max_wait}s"
    error "Check ArgoCD sync status: kubectl get applications -n argocd"
    error "Check ArgoCD logs: kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller"
    exit 1
}

# ==============================================================================
# Step 3: Generate TLS certificates (unblocks Wave 5 — Istio Gateway)
# ==============================================================================
generate_certs() {
    step "Step 3: Generating TLS certificates for Istio Gateway"
    log "This creates the 'istio-gateway-tls' secret that Wave 5 (Gateway) requires."
    log "ArgoCD will self-heal Wave 5 automatically once the secret exists."
    echo ""
    "${SCRIPT_DIR}/02-generate-certs.sh"
}

# ==============================================================================
# Step 4: Wait for Ollama to be Running (Wave 3)
# ==============================================================================
wait_for_ollama() {
    step "Step 4: Waiting for Ollama deployment (Wave 3)"

    log "Wave 3 deploys Ollama. GPU node provisioning may add a few minutes."

    local max_wait=600  # 10 min
    local interval=20
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        READY=$(kubectl get deployment ollama -n ollama \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        READY="${READY:-0}"

        if [[ "$READY" -ge 1 ]]; then
            log "Ollama is running (${READY} replica ready)"
            log "Model loader job (Wave 4) will pull qwen3-coder:32b in the background."
            return
        fi

        echo "  [${waited}s] Waiting for Ollama (${READY}/1 ready)..."
        sleep "$interval"
        waited=$((waited + interval))
    done

    warn "Ollama not ready after ${max_wait}s — GPU node may still be initialising."
    warn "This does not block Kong setup. Check later: kubectl get pods -n ollama"
}

# ==============================================================================
# Step 5 & 6 (optional): Kong Konnect Cloud AI Gateway
# ==============================================================================
setup_kong() {
    if [[ -z "${KONNECT_TOKEN:-}" || -z "${KONNECT_REGION:-}" ]]; then
        echo ""
        warn "KONNECT_TOKEN or KONNECT_REGION not set — skipping Kong setup."
        warn "To enable Kong team access:"
        warn "  1. Set KONNECT_TOKEN and KONNECT_REGION in .env"
        warn "  2. Run: ./scripts/03-setup-cloud-gateway.sh"
        warn "  3. Run: ./scripts/04-post-setup.sh"
        return
    fi

    step "Step 5: Setting up Kong Konnect Cloud AI Gateway"
    log "Network provisioning takes ~30 minutes. The script polls automatically."
    echo ""
    "${SCRIPT_DIR}/03-setup-cloud-gateway.sh"

    step "Step 6: Post-setup — NLB discovery + Kong config sync"
    "${SCRIPT_DIR}/04-post-setup.sh"
}

# ==============================================================================
# Summary
# ==============================================================================
show_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Setup Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [[ -n "${KONNECT_TOKEN:-}" ]]; then
        echo "  Kong Cloud AI Gateway mode (team access):"
        echo ""
        echo "  Get your Kong proxy URL from:"
        echo "  https://cloud.konghq.com → Gateway Manager → Data Plane Nodes"
        echo ""
        echo "  Then connect:"
        echo "    source claude-switch.sh ollama \\"
        echo "      --endpoint https://<KONG_PROXY_URL> \\"
        echo "      --apikey <your-api-key>"
    else
        echo "  Local mode (port-forward — single user):"
        echo ""
        echo "    source claude-switch.sh local"
    fi

    echo ""
    echo "  Run Claude Code:"
    echo "    claude --model qwen3-coder:32b"
    echo ""
    echo "  Monitor ArgoCD (model pull may take 10-30 min depending on speed):"
    echo "    kubectl get applications -n argocd"
    echo "    kubectl logs -n ollama -l app=model-loader -f"
    echo ""
    echo "  Scale to zero when done (stop billing):"
    echo "    kubectl scale deployment ollama -n ollama --replicas=0"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Ollama on EKS — Post-Terraform Setup${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

configure_kubectl
wait_for_namespaces
generate_certs
wait_for_ollama
setup_kong
show_summary
