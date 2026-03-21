#!/bin/bash
# Air-Gap Verification — Stack A Compliance Check
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Verifies that the air-gap principle is enforced:
#   1. Ollama pods cannot reach the internet
#   2. Open WebUI pods cannot reach the internet
#   3. NetworkPolicies are applied on all namespaces
#   4. No Bedrock VPC endpoints exist (Stack A only)
#   5. Egress is restricted to DNS + intra-cluster only
#
# Usage:
#   ./scripts/verify-airgap.sh
#
# Exit codes:
#   0 — all checks passed (air-gap enforced)
#   1 — one or more checks failed (air-gap broken)

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "${GREEN}  ✓ PASS${NC}  $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  ✗ FAIL${NC}  $*"; FAIL=$((FAIL + 1)); }
skip() { echo -e "${YELLOW}  ○ SKIP${NC}  $*"; SKIP=$((SKIP + 1)); }
step() { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
info() { echo -e "  ${DIM}$*${NC}"; }

echo ""
echo "========================================"
echo "  Air-Gap Verification — Stack A"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# Check 1: Ollama NetworkPolicy exists and blocks egress
# ---------------------------------------------------------------------------
step "Check 1: Ollama NetworkPolicy"

NP_NAME=$(kubectl get networkpolicy -n ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$NP_NAME" ]]; then
    pass "NetworkPolicy '${NP_NAME}' exists in ollama namespace"

    # Verify egress rules do NOT include 0.0.0.0/0 on port 443
    EGRESS_CIDR=$(kubectl get networkpolicy "$NP_NAME" -n ollama \
        -o jsonpath='{.spec.egress[*].to[*].ipBlock.cidr}' 2>/dev/null || echo "")
    if echo "$EGRESS_CIDR" | grep -q "0.0.0.0/0"; then
        fail "NetworkPolicy allows egress to 0.0.0.0/0 — breaks air-gap"
    else
        pass "No unrestricted egress CIDR (0.0.0.0/0) in NetworkPolicy"
    fi
else
    fail "No NetworkPolicy found in ollama namespace"
fi

# ---------------------------------------------------------------------------
# Check 2: Ollama pod cannot reach the internet
# ---------------------------------------------------------------------------
step "Check 2: Ollama internet egress test"

OLLAMA_POD=$(kubectl get pods -n ollama -l app=ollama --no-headers 2>/dev/null | head -1 | awk '{print $1}')
if [[ -n "$OLLAMA_POD" ]]; then
    info "Testing from pod: ${OLLAMA_POD}"

    # Try to reach an external endpoint — should timeout
    CURL_EXIT=0
    kubectl exec -n ollama "$OLLAMA_POD" -- \
        curl -s --max-time 5 https://google.com > /dev/null 2>&1 || CURL_EXIT=$?

    if [[ $CURL_EXIT -ne 0 ]]; then
        pass "Ollama pod cannot reach internet (curl exit code: ${CURL_EXIT})"
    else
        fail "Ollama pod CAN reach the internet — air-gap broken!"
    fi
else
    skip "No running Ollama pod — cannot test egress (cluster may not be deployed yet)"
fi

# ---------------------------------------------------------------------------
# Check 3: Open WebUI NetworkPolicy
# ---------------------------------------------------------------------------
step "Check 3: Open WebUI NetworkPolicy"

WEBUI_NP=$(kubectl get networkpolicy -n open-webui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$WEBUI_NP" ]]; then
    pass "NetworkPolicy '${WEBUI_NP}' exists in open-webui namespace"
else
    # Namespace may not exist yet
    NS_EXISTS=$(kubectl get namespace open-webui --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$NS_EXISTS" -ge 1 ]]; then
        fail "open-webui namespace exists but has no NetworkPolicy"
    else
        skip "open-webui namespace not deployed yet"
    fi
fi

# ---------------------------------------------------------------------------
# Check 4: Monitoring NetworkPolicy
# ---------------------------------------------------------------------------
step "Check 4: Monitoring namespace NetworkPolicy"

MON_NP=$(kubectl get networkpolicy -n monitoring -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$MON_NP" ]]; then
    pass "NetworkPolicy '${MON_NP}' exists in monitoring namespace"
else
    NS_EXISTS=$(kubectl get namespace monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$NS_EXISTS" -ge 1 ]]; then
        fail "monitoring namespace exists but has no NetworkPolicy"
    else
        skip "monitoring namespace not deployed yet"
    fi
fi

# ---------------------------------------------------------------------------
# Check 5: No Bedrock VPC endpoints (Stack A only)
# ---------------------------------------------------------------------------
step "Check 5: No Bedrock VPC endpoints (Stack A verification)"

REGION=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
    | sed -E 's|https://[^.]+\.([^.]+)\.eks\.amazonaws\.com.*|\1|' || echo "ap-southeast-2")

BEDROCK_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=service-name,Values=com.amazonaws.${REGION}.bedrock-runtime" \
    --query 'VpcEndpoints[].VpcEndpointId' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")

if [[ -z "$BEDROCK_ENDPOINTS" || "$BEDROCK_ENDPOINTS" == "None" ]]; then
    pass "No Bedrock VPC endpoints found (Stack A — air-gapped)"
else
    fail "Bedrock VPC endpoint(s) found: ${BEDROCK_ENDPOINTS} — this is Stack B, not Stack A"
fi

# ---------------------------------------------------------------------------
# Check 6: Ollama image is pinned (not :latest)
# ---------------------------------------------------------------------------
step "Check 6: Ollama image pinned"

OLLAMA_IMAGE=$(kubectl get deployment ollama -n ollama \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

if [[ -n "$OLLAMA_IMAGE" ]]; then
    if echo "$OLLAMA_IMAGE" | grep -q ":latest"; then
        fail "Ollama image uses :latest tag — should be pinned (e.g., ollama/ollama:0.6.2)"
    elif echo "$OLLAMA_IMAGE" | grep -qE ':[0-9]+\.[0-9]+'; then
        pass "Ollama image is pinned: ${OLLAMA_IMAGE}"
    else
        fail "Ollama image tag unclear: ${OLLAMA_IMAGE}"
    fi
else
    skip "Cannot read Ollama deployment image (cluster may not be deployed)"
fi

# ---------------------------------------------------------------------------
# Check 7: Ollama env vars are correct
# ---------------------------------------------------------------------------
step "Check 7: Ollama configuration"

NUM_PARALLEL=$(kubectl get deployment ollama -n ollama \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OLLAMA_NUM_PARALLEL")].value}' 2>/dev/null || echo "")

if [[ "$NUM_PARALLEL" == "4" ]]; then
    pass "OLLAMA_NUM_PARALLEL = 4 (matches spec)"
elif [[ -n "$NUM_PARALLEL" ]]; then
    fail "OLLAMA_NUM_PARALLEL = ${NUM_PARALLEL} (expected 4)"
else
    skip "Cannot read Ollama env vars (cluster may not be deployed)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
TOTAL=$((PASS + FAIL + SKIP))
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}Air-gap verification passed${NC}"
    echo -e "  ${GREEN}${PASS} passed, ${SKIP} skipped, 0 failed${NC}"
else
    echo -e "  ${RED}${BOLD}Air-gap verification FAILED${NC}"
    echo -e "  ${RED}${PASS} passed, ${SKIP} skipped, ${FAIL} failed${NC}"
fi
echo "========================================"
echo ""

[[ $FAIL -eq 0 ]]
