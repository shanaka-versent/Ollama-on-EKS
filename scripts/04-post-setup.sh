#!/bin/bash
# Post-Setup — Discover NLB + Verify CloudFront + API Gateway
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Run this AFTER terraform apply + ArgoCD sync:
#   1. Reads Terraform outputs (CloudFront, API Gateway, API Key)
#   2. Waits for the Istio Gateway NLB to be provisioned
#   3. Tests the CloudFront → API Gateway → Ollama chain
#   4. Shows connection details
#
# Usage:
#   ./scripts/04-post-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Read Terraform outputs
# ---------------------------------------------------------------------------
read_terraform_outputs() {
    log "Reading Terraform outputs..."

    if [[ ! -d "${TERRAFORM_DIR}/.terraform" ]]; then
        error "Terraform not initialized. Run deploy-stack-a.sh first."
        exit 1
    fi

    VPC_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw vpc_id 2>/dev/null || echo "N/A")
    CLOUDFRONT_DOMAIN=$(terraform -chdir="$TERRAFORM_DIR" output -raw cloudfront_domain 2>/dev/null || echo "N/A")
    API_ENDPOINT=$(terraform -chdir="$TERRAFORM_DIR" output -raw api_gateway_endpoint 2>/dev/null || echo "N/A")
    API_KEY_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw api_key_id 2>/dev/null || echo "N/A")
    REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw region 2>/dev/null || echo "")
    if [[ -z "$REGION" ]]; then
        error "Could not read region from Terraform outputs. Check: terraform -chdir=terraform output"
        exit 1
    fi

    echo ""
    log "Infrastructure Details:"
    echo "  VPC ID:             ${VPC_ID}"
    echo "  CloudFront Domain:  ${CLOUDFRONT_DOMAIN}"
    echo "  API Gateway:        ${API_ENDPOINT}"
    echo "  API Key ID:         ${API_KEY_ID}"
    echo "  Region:             ${REGION}"
    echo ""
}

# ---------------------------------------------------------------------------
# Get Istio Gateway NLB endpoint
# ---------------------------------------------------------------------------
get_gateway_endpoint() {
    log "Checking Istio Gateway NLB..."
    echo ""

    for i in {1..30}; do
        GATEWAY_STATUS=$(kubectl get gateway -n istio-system ollama-gateway \
            -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
        if [[ "$GATEWAY_STATUS" == "True" ]]; then
            log "Gateway is ready"
            break
        fi
        if [[ $i -eq 30 ]]; then
            warn "Timeout waiting for Gateway. It may still be provisioning."
            warn "Check: kubectl get gateway -n istio-system"
            return
        fi
        echo -n "."
        sleep 10
    done

    NLB_HOSTNAME=$(kubectl get gateway -n istio-system ollama-gateway \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "pending")

    echo ""
    echo "  NLB DNS: ${NLB_HOSTNAME}"
    echo "  This NLB is fronted by API Gateway via VPC Link."
    echo ""
}

# ---------------------------------------------------------------------------
# Test CloudFront endpoint
# ---------------------------------------------------------------------------
test_endpoint() {
    if [[ "$CLOUDFRONT_DOMAIN" == "N/A" || -z "$CLOUDFRONT_DOMAIN" ]]; then
        warn "CloudFront domain not available yet."
        return
    fi

    log "Testing CloudFront → API Gateway → Ollama chain..."

    # Get API key value
    API_KEY=$(aws apigateway get-api-key --api-key "$API_KEY_ID" \
        --include-value --query value --output text 2>/dev/null || echo "")

    if [[ -z "$API_KEY" ]]; then
        warn "Could not retrieve API key. Test manually."
        return
    fi

    # Test /api/tags (list models)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        "https://${CLOUDFRONT_DOMAIN}/api/tags" \
        -H "x-api-key: ${API_KEY}" \
        --connect-timeout 10 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" == "200" ]]; then
        log "CloudFront reachable — HTTP ${HTTP_CODE}"
        MODELS=$(curl -s "https://${CLOUDFRONT_DOMAIN}/api/tags" \
            -H "x-api-key: ${API_KEY}" \
            --connect-timeout 10 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); [print('    '+m['name']) for m in d.get('models',[])]" 2>/dev/null || true)
        if [[ -n "$MODELS" ]]; then
            log "Available models:"
            echo "$MODELS"
        fi
    else
        warn "CloudFront returned HTTP ${HTTP_CODE} — Ollama may still be starting up."
        warn "Wait for model loading to complete, then retry."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Post-Setup — CloudFront + API Gateway"
    echo "  Stack A (Air-Gapped)"
    echo "=============================================="
    echo ""

    read_terraform_outputs
    get_gateway_endpoint
    test_endpoint

    echo ""
    echo "=========================================="
    echo "  Connect to Your Private LLM"
    echo "=========================================="
    echo ""
    echo "  Via CloudFront (recommended):"
    echo "    API_KEY=\$(aws apigateway get-api-key --api-key ${API_KEY_ID} --include-value --query value --output text)"
    echo "    curl https://${CLOUDFRONT_DOMAIN}/v1/chat/completions \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -H \"x-api-key: \$API_KEY\" \\"
    echo "      -d '{\"model\": \"qwen3.5:122b-a10b\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
    echo ""
    echo "  Via port-forward (direct, no API key):"
    echo "    kubectl port-forward -n ollama svc/ollama 11434:11434"
    echo "    curl http://localhost:11434/v1/chat/completions \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -d '{\"model\": \"qwen3.5:122b-a10b\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
    echo ""
    echo "  Open WebUI (browser):"
    echo "    kubectl port-forward -n open-webui svc/open-webui 8080:8080"
    echo "    Open: http://localhost:8080"
    echo ""
}

main "$@"
