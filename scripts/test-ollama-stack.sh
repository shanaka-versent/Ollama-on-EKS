#!/bin/bash
# Ollama Stack Integration Test — Stack A (Air-Gapped)
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Tests the full stack end-to-end:
#   1. CloudFront + API Gateway reachability
#   2. Send a test prompt via CloudFront → API GW → NLB → Istio → Ollama
#   3. Scale down the GPU node group
#   4. Scale up the GPU node group
#   5. Scale down again
#   6. Air-gap verification
#
# Usage:
#   ./scripts/test-ollama-stack.sh
#
# Prerequisites:
#   - AWS CLI configured (aws sts get-caller-identity works)
#   - kubectl context pointing to EKS cluster
#   - Terraform outputs available

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}  ✓ PASS${NC}  $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  ✗ FAIL${NC}  $*"; FAIL=$((FAIL + 1)); }
step() { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
info() { echo -e "  ${DIM}$*${NC}"; }
result() { echo -e "  ${YELLOW}→${NC} $*"; }

echo ""
echo "========================================"
echo "  Ollama Stack Integration Test"
echo "  Stack A (Air-Gapped)"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# Load config from Terraform outputs
# ---------------------------------------------------------------------------
CLUSTER_NAME=$(terraform -chdir="$ROOT_DIR/terraform" output -raw eks_cluster_name 2>/dev/null) \
  || { echo -e "${RED}ERROR: could not read eks_cluster_name from Terraform outputs${NC}"; exit 1; }
NODE_GROUP=$(terraform -chdir="$ROOT_DIR/terraform" output -raw gpu_node_group_name 2>/dev/null) \
  || { echo -e "${RED}ERROR: could not read gpu_node_group_name from Terraform outputs${NC}"; exit 1; }
REGION=$(terraform -chdir="$ROOT_DIR/terraform" output -raw region 2>/dev/null) \
  || { echo -e "${RED}ERROR: could not read region from Terraform outputs${NC}"; exit 1; }
CLOUDFRONT_DOMAIN=$(terraform -chdir="$ROOT_DIR/terraform" output -raw cloudfront_domain 2>/dev/null) \
  || { echo -e "${RED}ERROR: could not read cloudfront_domain from Terraform outputs${NC}"; exit 1; }
API_KEY_ID=$(terraform -chdir="$ROOT_DIR/terraform" output -raw api_key_id 2>/dev/null) \
  || { echo -e "${RED}ERROR: could not read api_key_id from Terraform outputs${NC}"; exit 1; }

API_KEY=$(aws apigateway get-api-key --api-key "$API_KEY_ID" \
  --include-value --query value --output text 2>/dev/null) \
  || { echo -e "${RED}ERROR: could not retrieve API key value${NC}"; exit 1; }

MODEL="qwen3.5:122b-a10b"

info "Cluster       : $CLUSTER_NAME"
info "Node group    : $NODE_GROUP  ($REGION)"
info "CloudFront    : $CLOUDFRONT_DOMAIN"
info "Model         : $MODEL"

# ---------------------------------------------------------------------------
# Helper: wait for node group to be ACTIVE
# ---------------------------------------------------------------------------
wait_for_nodegroup_active() {
  local timeout=600
  local elapsed=0
  echo -n "  Waiting for node group ACTIVE"
  while true; do
    STATUS=$(aws eks describe-nodegroup \
      --cluster-name "$CLUSTER_NAME" \
      --nodegroup-name "$NODE_GROUP" \
      --region "$REGION" \
      --query 'nodegroup.status' --output text 2>/dev/null)
    if [[ "$STATUS" == "ACTIVE" ]]; then
      echo " — done"
      return 0
    fi
    echo -n "."
    sleep 15
    elapsed=$((elapsed + 15))
    if [[ $elapsed -ge $timeout ]]; then
      echo " — timed out"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Helper: get desired size
# ---------------------------------------------------------------------------
get_desired_size() {
  aws eks describe-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODE_GROUP" \
    --region "$REGION" \
    --query 'nodegroup.scalingConfig.desiredSize' \
    --output text 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: scale node group
# ---------------------------------------------------------------------------
scale_nodegroup() {
  local desired=$1
  aws eks update-nodegroup-config \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODE_GROUP" \
    --scaling-config minSize=0,maxSize=2,desiredSize="$desired" \
    --region "$REGION" > /dev/null 2>&1
  wait_for_nodegroup_active
}

# ===========================================================================
# TEST 1 — CloudFront + API Gateway reachability
# ===========================================================================
step "Test 1: CloudFront + API Gateway reachability"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "https://${CLOUDFRONT_DOMAIN}/api/tags" \
  -H "x-api-key: ${API_KEY}" \
  --connect-timeout 10 2>/dev/null)

MODELS_JSON=$(curl -s "https://${CLOUDFRONT_DOMAIN}/api/tags" \
  -H "x-api-key: ${API_KEY}" \
  --connect-timeout 10 2>/dev/null | python3 -c \
  "import sys,json; d=json.load(sys.stdin); [print('  '+m['name']) for m in d.get('models',[])]" 2>/dev/null || true)

result "HTTP status  = $HTTP_CODE"
result "Models available:"
echo "$MODELS_JSON"

if [[ "$HTTP_CODE" == "200" ]]; then
  pass "CloudFront + API Gateway reachable (HTTP $HTTP_CODE)"
else
  fail "CloudFront returned HTTP $HTTP_CODE"
fi

# ===========================================================================
# TEST 2 — Send prompt to Ollama via CloudFront
# ===========================================================================
step "Test 2: Send prompt — 'What is 2+2?'"

info "Sending via CloudFront → API GW → NLB → Istio → Ollama"
RESPONSE=$(curl -s "https://${CLOUDFRONT_DOMAIN}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  --connect-timeout 10 \
  --max-time 120 \
  -d "{\"model\": \"${MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"What is 2+2? Reply with the number only.\"}]}" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "ERROR")

result "Model response = '$RESPONSE'"

if echo "$RESPONSE" | grep -qE '\b4\b'; then
  pass "Ollama returned correct answer (contains '4')"
else
  fail "Unexpected response: '$RESPONSE'"
fi

# ===========================================================================
# TEST 3 — Air-gap verification
# ===========================================================================
step "Test 3: Air-gap compliance"

OLLAMA_POD=$(kubectl get pods -n ollama -l app=ollama --no-headers 2>/dev/null | head -1 | awk '{print $1}')
if [[ -n "$OLLAMA_POD" ]]; then
    CURL_EXIT=0
    kubectl exec -n ollama "$OLLAMA_POD" -- \
        curl -s --max-time 5 https://google.com > /dev/null 2>&1 || CURL_EXIT=$?

    if [[ $CURL_EXIT -ne 0 ]]; then
        pass "Ollama pod cannot reach internet (air-gap enforced)"
    else
        fail "Ollama pod CAN reach the internet — air-gap broken!"
    fi
else
    fail "No Ollama pod found"
fi

# ===========================================================================
# TEST 4 — Scale down
# ===========================================================================
step "Test 4: Scale down GPU node group"

info "Stopping Ollama pod (replicas → 0)..."
kubectl scale deployment ollama -n ollama --replicas=0 > /dev/null 2>&1

info "Scaling node group to 0..."
scale_nodegroup 0

DESIRED=$(get_desired_size)
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | { grep "g5\." || true; } | wc -l | tr -d ' ')

result "Desired size      = $DESIRED"
result "GPU nodes remaining = $NODE_COUNT"

if [[ "$DESIRED" == "0" ]] && [[ "$NODE_COUNT" == "0" ]]; then
  pass "GPU node group scaled to 0"
else
  fail "Scale down issue — desired=$DESIRED, GPU nodes=$NODE_COUNT"
fi

# ===========================================================================
# TEST 5 — Scale up
# ===========================================================================
step "Test 5: Scale up GPU node group"

info "Scaling node group to 1..."
scale_nodegroup 1

info "Waiting for GPU node to join cluster..."
kubectl wait --for=condition=ready node \
  -l "eks.amazonaws.com/nodegroup=$NODE_GROUP" \
  --timeout=600s > /dev/null 2>&1

info "Starting Ollama pod (replicas → 1)..."
kubectl scale deployment ollama -n ollama --replicas=1 > /dev/null 2>&1
kubectl wait --for=condition=ready pod \
  -l app=ollama -n ollama \
  --timeout=300s > /dev/null 2>&1

DESIRED=$(get_desired_size)
POD_STATUS=$(kubectl get pods -n ollama -l app=ollama \
  --no-headers 2>/dev/null | awk '{print $3}' | head -1)

result "Desired size = $DESIRED"
result "Pod status   = $POD_STATUS"

if [[ "$DESIRED" == "1" ]] && [[ "$POD_STATUS" == "Running" ]]; then
  pass "GPU node up, Ollama pod Running"
else
  fail "Scale up issue — desired=$DESIRED, pod=$POD_STATUS"
fi

# ===========================================================================
# TEST 6 — Scale down (final)
# ===========================================================================
step "Test 6: Scale down GPU node group (final)"

info "Stopping Ollama pod (replicas → 0)..."
kubectl scale deployment ollama -n ollama --replicas=0 > /dev/null 2>&1

info "Scaling node group to 0..."
scale_nodegroup 0

DESIRED=$(get_desired_size)
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | { grep "g5\." || true; } | wc -l | tr -d ' ')

if [[ "$DESIRED" == "0" ]] && [[ "$NODE_COUNT" == "0" ]]; then
  pass "GPU node group scaled to 0 cleanly"
else
  fail "Scale down issue — desired=$DESIRED, GPU nodes=$NODE_COUNT"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "========================================"
TOTAL=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${NC}"
else
  echo -e "  ${RED}${BOLD}$FAIL/$TOTAL tests failed${NC}"
fi
echo "========================================"
echo ""

[[ $FAIL -eq 0 ]]
