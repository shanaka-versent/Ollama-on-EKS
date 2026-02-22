#!/bin/bash
# Ollama Stack Integration Test
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Tests the full stack end-to-end:
#   1. Switch Claude Code to Ollama via Kong Cloud AI Gateway
#   2. Send a test prompt and verify the response
#   3. Scale down the GPU node group
#   4. Scale up the GPU node group
#   5. Scale down again
#   6. Switch Claude Code back to remote (Anthropic API)
#
# Usage:
#   ./scripts/test-ollama-stack.sh
#
# Prerequisites:
#   - AWS SSO logged in: aws sso login --profile <your-profile>
#   - .env with KONG_PROXY_URL and KONG_API_KEY (or pass as args)
#   - kubectl context pointing to EKS cluster
#
# Environment (can override via .env):
#   KONG_PROXY_URL   Kong Konnect proxy endpoint
#   KONG_API_KEY     API key for Kong authentication

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

pass() { echo -e "${GREEN}  ✓ PASS${NC}  $*"; ((PASS++)); }
fail() { echo -e "${RED}  ✗ FAIL${NC}  $*"; ((FAIL++)); }
step() { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
info() { echo -e "  ${DIM}$*${NC}"; }
result() { echo -e "  ${YELLOW}→${NC} $*"; }

echo ""
echo "========================================"
echo "  Ollama Stack Integration Test"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
ENV_FILE="$ROOT_DIR/.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

KONG_PROXY_URL="${KONG_PROXY_URL:-https://d509717478.gateways.konggateway.com}"
KONG_API_KEY="${KONG_API_KEY:-jFwezt8cwc8skNQnfCLN}"
MODEL="${MODEL:-qwen3-coder:30b}"
AWS_PROFILE="${AWS_PROFILE:-stax-stax-au1-versent-innovation}"

export AWS_PROFILE

info "Kong endpoint : $KONG_PROXY_URL"
info "Model         : $MODEL"

# Resolve cluster values from Terraform outputs
CLUSTER_NAME=$(terraform -chdir="$ROOT_DIR/terraform" output -raw eks_cluster_name 2>/dev/null) \
  || { echo -e "${RED}ERROR: could not read eks_cluster_name from Terraform outputs${NC}"; exit 1; }
NODE_GROUP=$(terraform -chdir="$ROOT_DIR/terraform" output -raw gpu_node_group_name 2>/dev/null) \
  || { echo -e "${RED}ERROR: could not read gpu_node_group_name from Terraform outputs${NC}"; exit 1; }
REGION=$(terraform -chdir="$ROOT_DIR/terraform" output -raw region 2>/dev/null) \
  || { echo -e "${RED}ERROR: could not read region from Terraform outputs${NC}"; exit 1; }

info "Cluster       : $CLUSTER_NAME"
info "Node group    : $NODE_GROUP  ($REGION)"

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
# Helper: get scaling config
# ---------------------------------------------------------------------------
get_scaling_config() {
  aws eks describe-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODE_GROUP" \
    --region "$REGION" \
    --query 'nodegroup.scalingConfig' \
    --output json 2>/dev/null
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
# TEST 1 — Switch to Claude local (Ollama via Kong)
# ===========================================================================
step "Test 1: Switch Claude to Ollama via Kong"

source "$ROOT_DIR/claude-switch.sh" ollama \
  --endpoint "$KONG_PROXY_URL" \
  --apikey "$KONG_API_KEY" > /dev/null 2>&1

result "ANTHROPIC_BASE_URL  = ${ANTHROPIC_BASE_URL:-not set}"
result "ANTHROPIC_AUTH_TOKEN = ${ANTHROPIC_AUTH_TOKEN:0:8}..."

if [[ "${ANTHROPIC_BASE_URL:-}" == "$KONG_PROXY_URL" ]] && \
   [[ "${ANTHROPIC_AUTH_TOKEN:-}" == "$KONG_API_KEY" ]]; then
  pass "Claude switched to Ollama mode"
else
  fail "Claude env vars not set correctly"
fi

# ===========================================================================
# TEST 2 — Kong reachability
# ===========================================================================
step "Test 2: Kong Gateway reachability"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "${KONG_PROXY_URL}/api/tags" \
  -H "apikey: ${KONG_API_KEY}" \
  --connect-timeout 10 2>/dev/null)

MODELS_JSON=$(curl -s "${KONG_PROXY_URL}/api/tags" \
  -H "apikey: ${KONG_API_KEY}" \
  --connect-timeout 10 2>/dev/null | python3 -c \
  "import sys,json; d=json.load(sys.stdin); [print('  '+m['name']) for m in d.get('models',[])]" 2>/dev/null || true)

result "HTTP status  = $HTTP_CODE"
result "Models available:"
echo "$MODELS_JSON"

if [[ "$HTTP_CODE" == "200" ]]; then
  pass "Kong Gateway reachable (HTTP $HTTP_CODE)"
else
  fail "Kong Gateway returned HTTP $HTTP_CODE"
fi

# ===========================================================================
# TEST 3 — Send prompt to Ollama: 2+2
# ===========================================================================
step "Test 3: Send prompt to Ollama — 'What is 2+2?'"

info "Sending prompt via: claude -p ... --model $MODEL"
RESPONSE=$(claude -p "What is 2+2? Reply with the number only, no explanation." \
  --model "$MODEL" 2>/dev/null || true)

result "Model response = '$RESPONSE'"

if echo "$RESPONSE" | grep -qE '\b4\b'; then
  pass "Ollama returned correct answer (contains '4')"
else
  fail "Unexpected response: '$RESPONSE'"
fi

# ===========================================================================
# TEST 4 — Scale down
# ===========================================================================
step "Test 4: Scale down GPU node group"

info "Stopping Ollama pod (replicas → 0)..."
kubectl scale deployment ollama -n ollama --replicas=0 > /dev/null 2>&1

info "Scaling node group to 0..."
scale_nodegroup 0

SCALING=$(get_scaling_config)
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "g5\." || echo "0")
POD_STATUS=$(kubectl get deployment ollama -n ollama --no-headers 2>/dev/null | awk '{print $2}')

result "Node group scaling = $SCALING"
result "GPU nodes in cluster = $NODE_COUNT"
result "Ollama deployment    = $POD_STATUS"

DESIRED=$(echo "$SCALING" | python3 -c "import sys,json; print(json.load(sys.stdin)['desiredSize'])" 2>/dev/null || echo "-1")
if [[ "$DESIRED" == "0" ]] && [[ "$NODE_COUNT" == "0" ]]; then
  pass "GPU node group scaled to 0, GPU node gone"
else
  fail "Scale down issue — desired=$DESIRED, GPU nodes remaining=$NODE_COUNT"
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

SCALING=$(get_scaling_config)
NODE_NAME=$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=$NODE_GROUP" \
  --no-headers 2>/dev/null | awk '{print $1, $2, $5}')
POD_LINE=$(kubectl get pods -n ollama -l app=ollama \
  --no-headers 2>/dev/null | awk '{print $1, $3, $6}')

result "Node group scaling = $SCALING"
result "GPU node           = $NODE_NAME"
result "Ollama pod         = $POD_LINE"

DESIRED=$(echo "$SCALING" | python3 -c "import sys,json; print(json.load(sys.stdin)['desiredSize'])" 2>/dev/null || echo "-1")
POD_STATUS=$(kubectl get pods -n ollama -l app=ollama \
  --no-headers 2>/dev/null | awk '{print $3}' | head -1)

if [[ "$DESIRED" == "1" ]] && [[ "$POD_STATUS" == "Running" ]]; then
  pass "GPU node up, Ollama pod Running"
else
  fail "Scale up issue — desired=$DESIRED, pod status=$POD_STATUS"
fi

# ===========================================================================
# TEST 6 — Scale down again
# ===========================================================================
step "Test 6: Scale down GPU node group (final)"

info "Stopping Ollama pod (replicas → 0)..."
kubectl scale deployment ollama -n ollama --replicas=0 > /dev/null 2>&1

info "Scaling node group to 0..."
scale_nodegroup 0

SCALING=$(get_scaling_config)
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "g5\." || echo "0")
POD_STATUS=$(kubectl get deployment ollama -n ollama --no-headers 2>/dev/null | awk '{print $2}')

result "Node group scaling = $SCALING"
result "GPU nodes in cluster = $NODE_COUNT"
result "Ollama deployment    = $POD_STATUS"

DESIRED=$(echo "$SCALING" | python3 -c "import sys,json; print(json.load(sys.stdin)['desiredSize'])" 2>/dev/null || echo "-1")
if [[ "$DESIRED" == "0" ]] && [[ "$NODE_COUNT" == "0" ]]; then
  pass "GPU node group scaled to 0 cleanly"
else
  fail "Scale down issue — desired=$DESIRED, GPU nodes remaining=$NODE_COUNT"
fi

# ===========================================================================
# TEST 7 — Switch back to remote
# ===========================================================================
step "Test 7: Switch Claude back to remote (Anthropic API)"

source "$ROOT_DIR/claude-switch.sh" remote > /dev/null 2>&1

result "ANTHROPIC_BASE_URL  = ${ANTHROPIC_BASE_URL:-unset}"
result "KONG_PROXY_URL      = ${KONG_PROXY_URL:-unset}"
result "ANTHROPIC_AUTH_TOKEN = ${ANTHROPIC_AUTH_TOKEN:-unset}"

if [[ -z "${ANTHROPIC_BASE_URL:-}" ]] && [[ -z "${KONG_PROXY_URL:-}" ]]; then
  pass "Claude switched back to remote mode"
else
  fail "Remote vars not cleared — ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-} KONG_PROXY_URL=${KONG_PROXY_URL:-}"
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
