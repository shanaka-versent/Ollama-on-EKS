#!/bin/bash
# Post-Terraform Setup — Stack A (Air-Gapped)
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Runs post-terraform steps after `terraform apply`:
#   1. Configure kubectl from Terraform outputs
#   2. Wait for ArgoCD to sync namespaces (Wave 1)
#   3. Wait for cert-manager to issue TLS certs (automated)
#   4. Wait for Ollama to be ready (Wave 3)
#   5. Show connection details (CloudFront + API Gateway)
#
# Usage:
#   ./scripts/01-setup.sh
#
# Prerequisites:
#   - terraform apply completed successfully
#   - awscli, kubectl installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

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
    AWS_REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw region 2>/dev/null || echo "")

    if [[ -z "$EKS_CLUSTER_NAME" ]]; then
        error "Could not read eks_cluster_name from Terraform outputs."
        error "Is the cluster fully deployed? Check: terraform -chdir=terraform output"
        exit 1
    fi

    if [[ -z "$AWS_REGION" ]]; then
        error "Could not read region from Terraform outputs."
        error "Refusing to fall back to a default — wrong region would misconfigure kubectl."
        error "Check: terraform -chdir=terraform output region"
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
    step "Step 2: Waiting for ArgoCD Wave 1 — namespaces"

    log "ArgoCD syncs in waves. Wave 1 creates namespaces (~5-10 min after terraform apply)."
    log "Watching for: istio-system + ollama"

    local max_wait=900  # 15 min
    local interval=15
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        local istio_ns ollama_ns
        istio_ns=$(kubectl get namespace istio-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ollama_ns=$(kubectl get namespace ollama --no-headers 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$istio_ns" -ge 1 && "$ollama_ns" -ge 1 ]]; then
            log "Both namespaces are ready"
            echo ""
            kubectl get applications -n argocd 2>/dev/null || true
            return
        fi

        echo -n "  [${waited}s] Waiting for namespaces"
        if [[ "$istio_ns" -lt 1 ]]; then echo -n " (istio-system missing)"; fi
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
# Step 3: Wait for cert-manager TLS certificates
# ==============================================================================
wait_for_certs() {
    step "Step 3: Waiting for cert-manager TLS certificates"

    log "cert-manager auto-generates TLS certs for Istio Gateway."
    log "Certificate: *.ollama.internal (90-day duration, 30-day auto-renewal)"

    local max_wait=300
    local interval=10
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        CERT_READY=$(kubectl get certificate -n istio-system istio-gateway-cert \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

        if [[ "$CERT_READY" == "True" ]]; then
            log "TLS certificate is ready"
            return
        fi

        echo "  [${waited}s] Waiting for certificate (status: ${CERT_READY:-pending})..."
        sleep "$interval"
        waited=$((waited + interval))
    done

    warn "Certificate not ready after ${max_wait}s — cert-manager may still be initialising."
    warn "Check: kubectl get certificate -n istio-system"
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
            return
        fi

        echo "  [${waited}s] Waiting for Ollama (${READY}/1 ready)..."
        sleep "$interval"
        waited=$((waited + interval))
    done

    warn "Ollama not ready after ${max_wait}s — GPU node may still be initialising."
    warn "Check pods: kubectl get pods -n ollama"
    warn "Check nodes: kubectl get nodes"
}

# ==============================================================================
# Summary
# ==============================================================================
show_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Setup Complete — Stack A (Air-Gapped)${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    CLOUDFRONT=$(terraform -chdir="$TERRAFORM_DIR" output -raw cloudfront_domain 2>/dev/null || echo "")
    API_KEY_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw api_key_id 2>/dev/null || echo "")

    if [[ -z "$CLOUDFRONT" ]]; then
        warn "Could not read cloudfront_domain — CDN may not be deployed yet"
        CLOUDFRONT="<not-available>"
    fi
    if [[ -z "$API_KEY_ID" ]]; then
        warn "Could not read api_key_id — API Gateway may not be deployed yet"
        API_KEY_ID="<not-available>"
    fi
    MODEL=$(grep '^ollama_model' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"//;s/".*//')

    echo "  CloudFront endpoint: https://${CLOUDFRONT}"
    echo ""
    echo "  Get API key:"
    echo "    aws apigateway get-api-key --api-key ${API_KEY_ID} --include-value --query value --output text"
    echo ""
    echo "  Test:"
    echo "    curl https://${CLOUDFRONT}/v1/chat/completions \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -H 'x-api-key: <YOUR_API_KEY>' \\"
    echo "      -d '{\"model\": \"${MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
    echo ""
    echo "  Open WebUI:  kubectl port-forward -n open-webui svc/open-webui 8080:8080"
    echo "  Grafana:     kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
    echo ""
    echo "  Scale down (stop billing): ./scripts/scale-down.sh"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Ollama on EKS — Post-Terraform Setup (Stack A)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

configure_kubectl
wait_for_namespaces
wait_for_certs
wait_for_ollama
show_summary
