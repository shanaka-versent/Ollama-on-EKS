#!/bin/bash
# Post-Setup - Discover NLB endpoint and sync Kong AI Gateway config
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Run this AFTER:
#   1. terraform apply
#   2. scripts/01-install-istio.sh
#   3. kubectl apply -f k8s/gateway.yaml && kubectl apply -f k8s/httproutes.yaml
#   4. scripts/03-setup-cloud-gateway.sh
#
# What it does:
#   1. Reads Terraform outputs
#   2. Waits for the Istio Gateway NLB to be provisioned
#   3. Updates deck/kong.yaml with the NLB hostname
#   4. Syncs Kong config to Konnect
#
# Usage:
#   ./scripts/04-post-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"
DECK_FILE="${REPO_DIR}/deck/kong.yaml"

ENV_FILE="${REPO_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Read Terraform outputs
# ---------------------------------------------------------------------------
read_terraform_outputs() {
    log "Reading Terraform outputs..."

    if [[ -d "${TERRAFORM_DIR}/.terraform" ]]; then
        VPC_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw vpc_id 2>/dev/null || echo "N/A")
        VPC_CIDR=$(terraform -chdir="$TERRAFORM_DIR" output -raw vpc_cidr 2>/dev/null || echo "N/A")
        TRANSIT_GW_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw transit_gateway_id 2>/dev/null || echo "N/A")
        RAM_SHARE_ARN=$(terraform -chdir="$TERRAFORM_DIR" output -raw ram_share_arn 2>/dev/null || echo "N/A")
    fi

    echo ""
    log "Infrastructure Details:"
    echo "  VPC ID:              ${VPC_ID:-N/A}"
    echo "  VPC CIDR:            ${VPC_CIDR:-N/A}"
    echo "  Transit Gateway ID:  ${TRANSIT_GW_ID:-N/A}"
    echo "  RAM Share ARN:       ${RAM_SHARE_ARN:-N/A}"
    echo ""
}

# ---------------------------------------------------------------------------
# Get Istio Gateway NLB endpoint
# ---------------------------------------------------------------------------
get_gateway_endpoint() {
    log "Fetching Istio Gateway NLB endpoint..."
    echo ""

    for i in {1..30}; do
        GATEWAY_STATUS=$(kubectl get gateway -n istio-ingress ollama-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null) || true
        if [ "$GATEWAY_STATUS" = "True" ]; then
            log "Gateway is ready"
            break
        fi
        if [ $i -eq 30 ]; then
            warn "Timeout waiting for Gateway. It may still be provisioning."
            warn "Check: kubectl get gateway -n istio-ingress"
            return
        fi
        echo -n "."
        sleep 10
    done

    NLB_HOSTNAME=$(kubectl get gateway -n istio-ingress ollama-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "pending")

    echo ""
    echo "=========================================="
    echo "  Istio Gateway NLB Endpoint"
    echo "=========================================="
    echo ""
    echo "  NLB DNS: ${NLB_HOSTNAME}"
    echo ""
    echo "  This is the entry point for Kong Cloud Gateway traffic."
    echo "  All services in deck/kong.yaml should use this NLB hostname."
    echo ""
}

# ---------------------------------------------------------------------------
# Update deck/kong.yaml with NLB hostname
# ---------------------------------------------------------------------------
update_deck_config() {
    if [[ -z "${NLB_HOSTNAME:-}" || "$NLB_HOSTNAME" == "pending" ]]; then
        warn "NLB hostname not available. Update deck/kong.yaml manually."
        return
    fi

    if [[ ! -f "$DECK_FILE" ]]; then
        warn "deck/kong.yaml not found at: ${DECK_FILE}"
        return
    fi

    log "Updating deck/kong.yaml with NLB hostname..."

    # Replace placeholder with actual NLB hostname
    if grep -q "REPLACE_WITH_NLB_HOSTNAME" "$DECK_FILE"; then
        sed -i.bak "s|REPLACE_WITH_NLB_HOSTNAME|${NLB_HOSTNAME}|g" "$DECK_FILE"
        rm -f "${DECK_FILE}.bak"
        log "  Updated deck/kong.yaml with: ${NLB_HOSTNAME}"
    else
        warn "  No placeholder found in deck/kong.yaml. You may need to update manually."
        echo "  Replace all service URLs with: http://${NLB_HOSTNAME}:80"
    fi
}

# ---------------------------------------------------------------------------
# Sync deck config to Konnect
# ---------------------------------------------------------------------------
sync_to_konnect() {
    if ! command -v deck &>/dev/null; then
        warn "deck CLI not found. Install it:"
        echo "  brew install kong/deck/deck"
        echo ""
        echo "Then sync manually:"
        echo "  deck gateway sync deck/kong.yaml \\"
        echo "    --konnect-addr https://\${KONNECT_REGION}.api.konghq.com \\"
        echo "    --konnect-token \$KONNECT_TOKEN \\"
        echo "    --konnect-control-plane-name ${KONNECT_CONTROL_PLANE_NAME:-ollama-ai-gateway}"
        return
    fi

    if [[ -z "${KONNECT_TOKEN:-}" || -z "${KONNECT_REGION:-}" ]]; then
        warn "KONNECT_TOKEN or KONNECT_REGION not set. Skipping deck sync."
        return
    fi

    log "Syncing Kong config to Konnect..."
    deck gateway sync "$DECK_FILE" \
        --konnect-addr "https://${KONNECT_REGION}.api.konghq.com" \
        --konnect-token "$KONNECT_TOKEN" \
        --konnect-control-plane-name "${KONNECT_CONTROL_PLANE_NAME:-ollama-ai-gateway}"

    log "Kong config synced to Konnect!"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Post-Setup — Kong Cloud AI Gateway"
    echo "  for Ollama on EKS"
    echo "=============================================="
    echo ""

    read_terraform_outputs
    get_gateway_endpoint
    update_deck_config
    sync_to_konnect

    echo ""
    echo "=========================================="
    echo "  Next: Connect Claude Code"
    echo "=========================================="
    echo ""
    echo "  Get your Kong proxy URL from Konnect UI:"
    echo "  https://cloud.konghq.com → Gateway Manager → Data Plane Nodes"
    echo ""
    echo "  Then run:"
    echo "  source claude-switch.sh ollama --endpoint https://<KONG_PROXY_URL>"
    echo ""
}

main "$@"
