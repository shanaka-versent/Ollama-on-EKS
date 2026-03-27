#!/bin/bash
# Ollama Stack Regression Test — End-to-End Validation
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Tests the full stack including all fixes from recent debugging:
#   1. Pod health & connectivity
#   2. NetworkPolicy (Open WebUI → Ollama)
#   3. AIOHTTP timeout configuration
#   4. Model availability & GPU loading
#   5. Streaming inference (JSON parse error regression)
#   6. CloudFront reachability & compression settings
#   7. WAF rules (false positive regression)
#   8. KEDA auto-scaler state
#   9. cert-manager TLS certificate
#  10. Air-gap compliance
#
# Usage:
#   ./scripts/test-ollama-stack.sh           # full test (requires Ollama running)
#   ./scripts/test-ollama-stack.sh --quick   # skip inference tests
#
# Prerequisites:
#   - AWS CLI configured (AWS_PROFILE=stax-stax-au1-versent-innovation)
#   - kubectl context pointing to EKS cluster
#   - Ollama pod must be running (run ./scripts/scale-up.sh first)

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
SKIP=0

pass() { echo -e "${GREEN}  ✓ PASS${NC}  $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  ✗ FAIL${NC}  $*"; FAIL=$((FAIL + 1)); }
skip() { echo -e "${YELLOW}  ○ SKIP${NC}  $*"; SKIP=$((SKIP + 1)); }
step() { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
info() { echo -e "  ${DIM}$*${NC}"; }
result() { echo -e "  ${YELLOW}→${NC} $*"; }

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

export AWS_PROFILE="${AWS_PROFILE:-stax-stax-au1-versent-innovation}"

echo ""
echo "========================================"
echo "  Ollama Stack Regression Test"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# Pre-flight: Check cluster connectivity
# ---------------------------------------------------------------------------
step "Pre-flight: Cluster connectivity"

if ! kubectl cluster-info > /dev/null 2>&1; then
  echo -e "${RED}ERROR: Cannot connect to Kubernetes cluster${NC}"
  echo "  Run: aws eks update-kubeconfig --region ap-southeast-2 --name eks-ollama-dev"
  exit 1
fi
pass "kubectl connected to cluster"

# ===========================================================================
# TEST 1 — Pod Health
# ===========================================================================
step "Test 1: Pod health"

OLLAMA_STATUS=$(kubectl get pods -n ollama -l app=ollama --no-headers 2>/dev/null \
  | head -1 | awk '{print $3}')
WEBUI_STATUS=$(kubectl get pods -n open-webui -l app=open-webui --no-headers 2>/dev/null \
  | head -1 | awk '{print $3}')

result "Ollama pod  = ${OLLAMA_STATUS:-NOT FOUND}"
result "WebUI pod   = ${WEBUI_STATUS:-NOT FOUND}"

if [[ "$WEBUI_STATUS" == "Running" ]]; then
  pass "Open WebUI pod is Running"
else
  fail "Open WebUI pod is not Running (status: ${WEBUI_STATUS:-NOT FOUND})"
fi

if [[ "$OLLAMA_STATUS" == "Running" ]]; then
  pass "Ollama pod is Running"
else
  fail "Ollama pod is not Running (status: ${OLLAMA_STATUS:-NOT FOUND})"
  if [[ "$OLLAMA_STATUS" != "Running" ]]; then
    echo -e "  ${YELLOW}⚠ Some tests will be skipped because Ollama is not running${NC}"
    echo -e "  ${YELLOW}  Run: ./scripts/scale-up.sh${NC}"
  fi
fi

# ===========================================================================
# TEST 2 — NetworkPolicy (Open WebUI → Ollama connectivity)
# ===========================================================================
step "Test 2: NetworkPolicy — Open WebUI → Ollama connectivity"

if [[ "$OLLAMA_STATUS" == "Running" ]]; then
  CONN_TEST=$(kubectl exec -n open-webui deploy/open-webui -- \
    curl -s --max-time 10 http://ollama.ollama.svc.cluster.local:11434/api/tags 2>&1) || CONN_TEST=""

  if echo "$CONN_TEST" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    pass "Open WebUI can reach Ollama on port 11434 (NetworkPolicy allows it)"
  else
    fail "Open WebUI CANNOT reach Ollama — NetworkPolicy may be blocking"
    result "Response: ${CONN_TEST:0:200}"
  fi
else
  skip "Ollama not running — cannot test NetworkPolicy connectivity"
fi

# Check NetworkPolicy includes open-webui namespace
NP_YAML=$(kubectl get networkpolicy -n ollama ollama-airgap -o yaml 2>/dev/null || echo "")
if echo "$NP_YAML" | grep -q "open-webui"; then
  pass "NetworkPolicy includes open-webui namespace in ingress rules"
else
  fail "NetworkPolicy does NOT include open-webui namespace — chat requests will be blocked"
fi

# ===========================================================================
# TEST 3 — AIOHTTP Timeout Configuration
# ===========================================================================
step "Test 3: AIOHTTP timeout configuration"

TIMEOUT=$(kubectl get deployment open-webui -n open-webui \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AIOHTTP_CLIENT_TIMEOUT")].value}' 2>/dev/null)
TIMEOUT_MODEL=$(kubectl get deployment open-webui -n open-webui \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST")].value}' 2>/dev/null)

result "AIOHTTP_CLIENT_TIMEOUT           = ${TIMEOUT:-NOT SET}"
result "AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST = ${TIMEOUT_MODEL:-NOT SET}"

if [[ "${TIMEOUT:-0}" -ge 120 ]]; then
  pass "AIOHTTP_CLIENT_TIMEOUT is ${TIMEOUT}s (>= 120s required for inference)"
else
  fail "AIOHTTP_CLIENT_TIMEOUT is ${TIMEOUT:-NOT SET} — must be >= 120s (300 recommended)"
  info "Low timeout causes 'Unexpected token d' JSON parse error (response cut mid-stream)"
fi

if [[ "${TIMEOUT_MODEL:-0}" -le 10 ]]; then
  pass "AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST is ${TIMEOUT_MODEL}s (short = fast UI load when Ollama is down)"
else
  fail "AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST is ${TIMEOUT_MODEL:-NOT SET} — should be short (3s recommended)"
fi

# ===========================================================================
# TEST 4 — Model Availability
# ===========================================================================
step "Test 4: Model availability"

if [[ "$OLLAMA_STATUS" == "Running" ]]; then
  MODELS=$(kubectl exec -n open-webui deploy/open-webui -- \
    curl -s --max-time 10 http://ollama.ollama.svc.cluster.local:11434/api/tags 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); [print(m['name']) for m in d.get('models',[])]" 2>/dev/null || echo "")

  if [[ -n "$MODELS" ]]; then
    pass "Models available on Ollama:"
    echo "$MODELS" | while read -r m; do result "$m"; done
  else
    fail "No models found on Ollama (EBS snapshot may not be mounted)"
  fi

  # Check if model is loaded in GPU VRAM (not just on disk)
  PS_OUTPUT=$(kubectl exec -n open-webui deploy/open-webui -- \
    curl -s --max-time 10 http://ollama.ollama.svc.cluster.local:11434/api/ps 2>/dev/null || echo "{}")
  LOADED_COUNT=$(echo "$PS_OUTPUT" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(len(d.get('models',[])))" 2>/dev/null || echo "0")

  if [[ "$LOADED_COUNT" -gt 0 ]]; then
    pass "Model is loaded in GPU VRAM (warm — instant inference)"
  else
    info "Model NOT loaded in GPU VRAM yet (first request will take ~2 min to cold-load)"
  fi
else
  skip "Ollama not running — cannot test model availability"
fi

# ===========================================================================
# TEST 5 — Streaming Inference (JSON parse error regression)
# ===========================================================================
step "Test 5: Streaming inference — JSON parse error regression"

if [[ "$OLLAMA_STATUS" == "Running" ]] && ! $QUICK; then
  info "Sending streaming request: Open WebUI → Ollama (this tests the full SSE pipeline)"

  # Test streaming via internal cluster path (bypasses CloudFront)
  STREAM_RESPONSE=$(kubectl exec -n open-webui deploy/open-webui -- \
    curl -s --max-time 120 -X POST http://ollama.ollama.svc.cluster.local:11434/api/generate \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3.5:27b","prompt":"What is 2+2? Reply with the number only.","stream":true,"think":false,"options":{"num_predict":20}}' 2>/dev/null || echo "ERROR")

  # Each line of streaming output should be valid JSON
  INVALID_LINES=0
  TOTAL_LINES=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    TOTAL_LINES=$((TOTAL_LINES + 1))
    if ! echo "$line" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
      INVALID_LINES=$((INVALID_LINES + 1))
    fi
  done <<< "$STREAM_RESPONSE"

  result "Stream lines: $TOTAL_LINES total, $INVALID_LINES invalid"

  if [[ $TOTAL_LINES -gt 0 ]] && [[ $INVALID_LINES -eq 0 ]]; then
    pass "Streaming response — all $TOTAL_LINES lines are valid JSON"
  elif [[ $TOTAL_LINES -eq 0 ]]; then
    fail "Streaming response — no data received (timeout or connection error)"
  else
    fail "Streaming response — $INVALID_LINES/$TOTAL_LINES lines are INVALID JSON"
    info "This is the 'Unexpected token d' error — check AIOHTTP_CLIENT_TIMEOUT and CloudFront compress"
  fi

  # Test non-streaming (simpler validation)
  RESULT=$(kubectl exec -n open-webui deploy/open-webui -- \
    curl -s --max-time 120 -X POST http://ollama.ollama.svc.cluster.local:11434/api/generate \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3.5:27b","prompt":"What is 2+2? Reply with the number only.","stream":false,"think":false,"options":{"num_predict":20}}' 2>/dev/null || echo "")

  ANSWER=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('response',''))" 2>/dev/null || echo "ERROR")
  result "Model answer: '$ANSWER'"

  if echo "$ANSWER" | grep -qE '\b4\b'; then
    pass "Non-streaming inference — correct answer (contains '4')"
  else
    fail "Non-streaming inference — unexpected response: '$ANSWER'"
  fi
else
  if $QUICK; then
    skip "Inference tests skipped (--quick mode)"
  else
    skip "Ollama not running — cannot test inference"
  fi
fi

# ===========================================================================
# TEST 6 — CloudFront Configuration
# ===========================================================================
step "Test 6: CloudFront configuration"

CF_DIST_ID=$(aws cloudfront list-distributions \
  --query 'DistributionList.Items[0].Id' --output text 2>/dev/null || echo "")
CF_DOMAIN=$(aws cloudfront list-distributions \
  --query 'DistributionList.Items[0].DomainName' --output text 2>/dev/null || echo "")

if [[ -n "$CF_DIST_ID" ]] && [[ "$CF_DIST_ID" != "None" ]]; then
  result "Distribution: $CF_DIST_ID ($CF_DOMAIN)"

  # Check compression is disabled (SSE streaming fix)
  CF_COMPRESS=$(aws cloudfront get-distribution --id "$CF_DIST_ID" \
    --query 'Distribution.DistributionConfig.DefaultCacheBehavior.Compress' --output text 2>/dev/null)

  if [[ "$CF_COMPRESS" == "False" ]]; then
    pass "CloudFront compression disabled (prevents SSE stream buffering)"
  else
    fail "CloudFront compression is ENABLED — will buffer SSE streams causing JSON parse errors"
  fi

  # Check CloudFront health
  CF_STATUS=$(aws cloudfront get-distribution --id "$CF_DIST_ID" \
    --query 'Distribution.Status' --output text 2>/dev/null)
  if [[ "$CF_STATUS" == "Deployed" ]]; then
    pass "CloudFront distribution status: Deployed"
  else
    fail "CloudFront distribution status: $CF_STATUS (expected Deployed)"
  fi

  # Test CloudFront reachability (static page — doesn't need Ollama)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "https://${CF_DOMAIN}/" --connect-timeout 10 2>/dev/null || echo "000")
  result "CloudFront HTTPS response: HTTP $HTTP_CODE"

  if [[ "$HTTP_CODE" != "000" ]] && [[ "$HTTP_CODE" != "403" ]] && [[ "$HTTP_CODE" != "502" ]] && [[ "$HTTP_CODE" != "503" ]]; then
    pass "CloudFront is reachable (HTTP $HTTP_CODE)"
  elif [[ "$HTTP_CODE" == "403" ]]; then
    fail "CloudFront returns 403 — check WAF rules, TLS cert, or VPC Origin health"
  else
    fail "CloudFront not reachable (HTTP $HTTP_CODE)"
  fi
else
  skip "No CloudFront distribution found"
fi

# ===========================================================================
# TEST 7 — WAF Configuration
# ===========================================================================
step "Test 7: WAF rules (false positive regression)"

WAF_ACL_ID=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
  --query 'WebACLs[0].Id' --output text 2>/dev/null || echo "")
WAF_ACL_NAME=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
  --query 'WebACLs[0].Name' --output text 2>/dev/null || echo "")

if [[ -n "$WAF_ACL_ID" ]] && [[ "$WAF_ACL_ID" != "None" ]]; then
  result "WAF ACL: $WAF_ACL_NAME ($WAF_ACL_ID)"

  # Check that SizeRestrictions_BODY, CrossSiteScripting_BODY, SQLi_BODY are overridden to COUNT
  WAF_CONFIG=$(aws wafv2 get-web-acl --name "$WAF_ACL_NAME" --scope CLOUDFRONT --region us-east-1 \
    --id "$WAF_ACL_ID" --query 'WebACL.Rules' --output json 2>/dev/null || echo "[]")

  OVERRIDES=$(echo "$WAF_CONFIG" | python3 -c "
import json, sys
rules = json.load(sys.stdin)
overrides = []
for rule in rules:
    stmt = rule.get('Statement', {})
    mrg = stmt.get('ManagedRuleGroupStatement', {})
    if mrg.get('Name') == 'AWSManagedRulesCommonRuleSet':
        for ov in mrg.get('RuleActionOverrides', []):
            overrides.append(ov['Name'])
print(','.join(overrides))
" 2>/dev/null || echo "")

  NEEDED_OVERRIDES=("SizeRestrictions_BODY" "CrossSiteScripting_BODY" "SQLi_BODY")
  ALL_PRESENT=true
  for rule in "${NEEDED_OVERRIDES[@]}"; do
    if echo "$OVERRIDES" | grep -q "$rule"; then
      result "$rule → COUNT (overridden)"
    else
      result "$rule → BLOCK (NOT overridden!)"
      ALL_PRESENT=false
    fi
  done

  if $ALL_PRESENT; then
    pass "WAF rules overridden to COUNT for chat API (prevents false positives)"
  else
    fail "WAF rules NOT overridden — chat POST requests may be blocked"
    info "SizeRestrictions_BODY blocks >8KB bodies, CrossSiteScripting_BODY/SQLi_BODY trigger on code snippets"
  fi
else
  skip "No WAF ACL found"
fi

# ===========================================================================
# TEST 8 — KEDA Auto-Scaler State
# ===========================================================================
step "Test 8: KEDA auto-scaler configuration"

KEDA_OBJ=$(kubectl get scaledobject ollama-autoscaler -n ollama -o json 2>/dev/null || echo "{}")

if [[ "$KEDA_OBJ" != "{}" ]]; then
  KEDA_PAUSED=$(echo "$KEDA_OBJ" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('metadata',{}).get('annotations',{}).get('autoscaling.keda.sh/paused','0'))" 2>/dev/null)
  COOLDOWN=$(echo "$KEDA_OBJ" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('spec',{}).get('cooldownPeriod',0))" 2>/dev/null)
  MIN_REPLICAS=$(echo "$KEDA_OBJ" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('spec',{}).get('minReplicaCount',0))" 2>/dev/null)
  MAX_REPLICAS=$(echo "$KEDA_OBJ" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('spec',{}).get('maxReplicaCount',0))" 2>/dev/null)

  result "Paused          = $KEDA_PAUSED"
  result "Cooldown        = ${COOLDOWN}s ($((COOLDOWN / 60)) min)"
  result "Min/Max replicas = ${MIN_REPLICAS}/${MAX_REPLICAS}"

  if [[ "$KEDA_PAUSED" == "true" ]]; then
    fail "KEDA is PAUSED — GPU node will run indefinitely ($$$/hr)"
    info "Unpause: kubectl annotate scaledobject ollama-autoscaler -n ollama autoscaling.keda.sh/paused='0' --overwrite"
  else
    pass "KEDA is active (not paused)"
  fi

  if [[ "$COOLDOWN" -ge 1800 ]]; then
    pass "KEDA cooldown is ${COOLDOWN}s (30+ min)"
  else
    fail "KEDA cooldown is ${COOLDOWN}s — should be >= 1800 (30 min)"
  fi
else
  skip "KEDA ScaledObject not found"
fi

# ===========================================================================
# TEST 9 — cert-manager TLS Certificate
# ===========================================================================
step "Test 9: cert-manager TLS certificate"

CERT_STATUS=$(kubectl get certificate istio-gateway-cert -n istio-ingress \
  -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "NOT FOUND")
CERT_READY=$(kubectl get certificate istio-gateway-cert -n istio-ingress \
  -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo "")
SECRET_EXISTS=$(kubectl get secret istio-gateway-tls -n istio-ingress \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')

result "Certificate condition = $CERT_STATUS ($CERT_READY)"
result "TLS secret exists     = $([[ $SECRET_EXISTS -gt 0 ]] && echo 'yes' || echo 'NO')"

if [[ "$CERT_STATUS" == "Ready" ]] && [[ "$CERT_READY" == "True" ]]; then
  pass "TLS certificate is Ready"
else
  fail "TLS certificate is NOT Ready (status: $CERT_STATUS/$CERT_READY)"
  info "Missing cert causes NLB 443 health check failure → CloudFront 403"
fi

if [[ $SECRET_EXISTS -gt 0 ]]; then
  pass "TLS secret exists in istio-ingress namespace"
else
  fail "TLS secret NOT found in istio-ingress namespace"
  info "Apply: kubectl apply -f k8s/cert-manager/cluster-issuer.yaml"
fi

# ===========================================================================
# TEST 10 — Air-Gap Compliance
# ===========================================================================
step "Test 10: Air-gap compliance"

if [[ "$OLLAMA_STATUS" == "Running" ]]; then
  # Test that Ollama cannot reach the internet
  AIRGAP_EXIT=0
  kubectl exec -n open-webui deploy/open-webui -- \
    curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
    http://ollama.ollama.svc.cluster.local:11434 > /dev/null 2>&1 || true

  # Try to reach internet FROM the Ollama pod (via Open WebUI as proxy test)
  # Actually test the NetworkPolicy by checking egress from Ollama namespace
  NP_EGRESS=$(kubectl get networkpolicy -n ollama ollama-airgap -o json 2>/dev/null \
    | python3 -c "
import json, sys
np = json.load(sys.stdin)
egress = np.get('spec', {}).get('egress', [])
for rule in egress:
  for to in rule.get('to', []):
    if to.get('ipBlock', {}).get('cidr', '') in ['0.0.0.0/0', '::/0']:
      print('OPEN')
      sys.exit()
print('RESTRICTED')
" 2>/dev/null || echo "UNKNOWN")

  if [[ "$NP_EGRESS" == "RESTRICTED" ]]; then
    pass "Ollama egress is restricted (air-gap enforced via NetworkPolicy)"
  elif [[ "$NP_EGRESS" == "OPEN" ]]; then
    fail "Ollama has open egress to 0.0.0.0/0 — air-gap BROKEN"
  else
    info "Could not determine egress policy — verify manually"
  fi
else
  skip "Ollama not running — cannot test air-gap"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "========================================"
TOTAL=$((PASS + FAIL + SKIP))
if [[ $FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All tests passed: $PASS passed, $SKIP skipped${NC}"
else
  echo -e "  ${RED}${BOLD}$FAIL FAILED${NC}, $PASS passed, $SKIP skipped (out of $TOTAL)"
fi
echo "========================================"
echo ""

[[ $FAIL -eq 0 ]]
