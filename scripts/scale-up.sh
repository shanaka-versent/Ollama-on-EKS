#!/bin/bash
# Scale up Ollama — Karpenter auto-provisions GPU node
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# With EKS Auto Mode + Karpenter: just scale the deployment to 1.
# Karpenter provisions a g5 GPU node automatically (~2-3 min).
# KEDA auto-scaling is paused during startup, then unpaused so
# the 30-min idle timer starts from when the model finishes loading.
#
# Usage:
#   ./scripts/scale-up.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# Safety trap: if script is interrupted (Ctrl+C, terminal close, kill),
# unpause KEDA so it can scale to zero. Without this, KEDA stays paused
# and the GPU node runs at $0.35-$1.90/hr until someone notices.
KEDA_WAS_PAUSED=false
cleanup_on_interrupt() {
  echo ""
  echo -e "  ${RED}Interrupted!${NC} Ensuring KEDA is unpaused..."
  if $KEDA_WAS_PAUSED; then
    kubectl annotate scaledobject ollama-autoscaler -n ollama \
      autoscaling.keda.sh/paused- \
      gpu-controller/paused-at- \
      --overwrite 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} KEDA unpaused — will scale to zero after idle timeout"
  fi
  exit 1
}
trap cleanup_on_interrupt INT TERM

echo ""
echo "========================================"
echo "  Scale Up — Start Ollama GPU Node"
echo "========================================"
echo ""

export AWS_PROFILE="${AWS_PROFILE:-stax-stax-au1-versent-innovation}"

# Check if already running
POD_STATUS=$(kubectl get pods -n ollama -l app=ollama \
  --no-headers 2>/dev/null | awk '{print $3}' | head -1)
if [[ "$POD_STATUS" == "Running" ]]; then
  echo -e "  ${YELLOW}Already running — Ollama pod is $POD_STATUS.${NC}"
  echo ""
  exit 0
fi

REPLICAS=$(kubectl get deployment ollama -n ollama -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
echo -e "  Current replicas : ${YELLOW}$REPLICAS${NC}"
echo -e "  Karpenter will provision a GPU node automatically (~2-3 min)"
echo ""

read -r -p "  Scale up now? [y/N] " confirm
if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
  echo ""
  echo "  Aborted."
  echo ""
  exit 0
fi

# Pause KEDA auto-scaling to prevent it from scaling back to 0 during startup
# Record pause timestamp so the EventBridge safety check knows when it was paused
echo ""
echo -e "${CYAN}${BOLD}==> Pausing KEDA auto-scaling...${NC}"
PAUSE_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if kubectl annotate scaledobject ollama-autoscaler -n ollama \
  autoscaling.keda.sh/paused="true" \
  gpu-controller/paused-at="$PAUSE_TIME" --overwrite 2>/dev/null; then
  KEDA_WAS_PAUSED=true
  echo -e "  ${GREEN}✓${NC} KEDA paused (safety check will auto-unpause after 15 min)"
else
  echo -e "  ${YELLOW}⚠${NC} KEDA ScaledObject not found (KEDA may not be deployed yet)"
fi

echo ""
echo -e "${CYAN}${BOLD}==> Scaling Ollama to 1 replica...${NC}"
kubectl scale deployment ollama -n ollama --replicas=1
echo -e "  ${GREEN}✓${NC} Deployment scaled to 1"

echo ""
echo -e "${CYAN}${BOLD}==> Waiting for GPU node + pod (this takes ~2-3 min)...${NC}"
echo -n "  Waiting for pod Running"
SECONDS=0
while true; do
  POD_STATUS=$(kubectl get pods -n ollama -l app=ollama \
    --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  if [[ "$POD_STATUS" == "Running" ]]; then
    echo " — done (${SECONDS}s)"
    break
  fi
  if [[ $SECONDS -gt 600 ]]; then
    echo ""
    echo -e "  ${RED}✗ Timeout after 10 min. Check: kubectl get pods -n ollama${NC}"
    exit 1
  fi
  echo -n "."
  sleep 10
done

# Show GPU node info
GPU_NODE=$(kubectl get pods -n ollama -l app=ollama -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
INSTANCE_TYPE=$(kubectl get node "$GPU_NODE" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")
CAPACITY_TYPE=$(kubectl get node "$GPU_NODE" -o jsonpath='{.metadata.labels.karpenter\.sh/capacity-type}' 2>/dev/null || echo "unknown")
echo -e "  ${GREEN}✓${NC} GPU node: $GPU_NODE ($INSTANCE_TYPE, $CAPACITY_TYPE)"

# Wait for Ollama to be ready (model loaded) before unpausing KEDA.
# "Running" only means the container started — the model still needs to load
# from the ephemeral EBS snapshot volume. If we unpause KEDA before the model
# is loaded, KEDA sees zero activity and immediately scales back to 0.
echo ""
echo -e "${CYAN}${BOLD}==> Waiting for Ollama API to be ready (model loading)...${NC}"
echo -n "  Waiting for model"
SECONDS=0
while true; do
  # Check if Ollama API responds and has at least one model on disk
  # Use Open WebUI pod for curl (Ollama container doesn't have curl)
  MODEL_COUNT=$(kubectl exec -n open-webui deploy/open-webui -- \
    curl -s --max-time 10 http://ollama.ollama.svc.cluster.local:11434/api/tags 2>/dev/null \
    | python3 -c "import json,sys; data=json.load(sys.stdin); print(len(data.get('models',[])))" 2>/dev/null || echo "0")
  if [[ "$MODEL_COUNT" -gt 0 ]]; then
    echo " — done (${SECONDS}s, $MODEL_COUNT model(s) on disk)"
    break
  fi
  if [[ $SECONDS -gt 300 ]]; then
    echo ""
    echo -e "  ${YELLOW}⚠${NC} Model not found on disk after 5 min — leaving KEDA paused"
    echo -e "  ${YELLOW}⚠${NC} Safety check will auto-unpause KEDA after 15 min"
    echo -e "  Check: kubectl exec -n ollama deploy/ollama -- ollama list"
    echo ""
    exit 0
  fi
  echo -n "."
  sleep 10
done

# Pre-load model into GPU memory with a warm-up inference request.
# /api/tags only checks models on disk — the model isn't in GPU VRAM until
# the first inference. Cold load from disk takes ~2 min. Without this step,
# the first user chat request would hang for 2 min.
echo ""
echo -e "${CYAN}${BOLD}==> Pre-loading model into GPU memory (warm-up request)...${NC}"
echo -e "  This takes ~2 min on cold start (loading weights from disk to GPU VRAM)"
echo -n "  Loading"
SECONDS=0
WARMUP_DONE=false
# Get the default model from the Ollama deployment env vars
DEFAULT_MODEL=$(kubectl get deployment ollama -n ollama \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OLLAMA_MODEL")].value}' 2>/dev/null)
DEFAULT_MODEL="${DEFAULT_MODEL:-qwen3.5:27b}"
while true; do
  # Use Open WebUI pod for curl (Ollama container doesn't have curl)
  RESPONSE=$(kubectl exec -n open-webui deploy/open-webui -- \
    curl -s --max-time 300 -X POST "http://ollama.ollama.svc.cluster.local:11434/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$DEFAULT_MODEL\",\"prompt\":\"hi\",\"stream\":false,\"think\":false,\"options\":{\"num_predict\":5}}" 2>/dev/null || echo "")
  if echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('done')" 2>/dev/null; then
    echo " — done (${SECONDS}s)"
    WARMUP_DONE=true
    break
  fi
  if [[ $SECONDS -gt 300 ]]; then
    echo ""
    echo -e "  ${YELLOW}⚠${NC} Warm-up timed out after 5 min — model may still be loading"
    echo -e "  First chat request will trigger the load instead"
    break
  fi
  echo -n "."
  sleep 10
done

if $WARMUP_DONE; then
  echo -e "  ${GREEN}✓${NC} Model loaded into GPU VRAM — ready for instant inference"
fi

# Do NOT unpause KEDA from this script. Let the EventBridge safety check
# handle it after the 15-min grace period. This prevents the race condition
# where KEDA unpauses, sees no Prometheus metrics yet (query lag), and
# immediately scales to 0 — killing the pod we just started.
#
# Flow: scale-up.sh pauses KEDA → 15 min grace → EventBridge unpauses KEDA
#       → KEDA checks triggers → if active, keeps running; if idle, scales to 0
echo ""
echo -e "${CYAN}${BOLD}==> KEDA stays paused (safety check will unpause after 30 min)${NC}"
echo -e "  ${GREEN}✓${NC} This prevents KEDA from immediately killing the pod"
echo -e "  ${GREEN}✓${NC} To stop manually: ./scripts/scale-down.sh (unpauses KEDA)"

echo ""
echo "========================================"
echo -e "  ${GREEN}${BOLD}Ollama is up and ready.${NC}"
echo "========================================"
echo ""
echo "  Test:"
echo "    kubectl exec -n ollama deploy/ollama -- ollama list"
echo ""
echo "  Stop (manual):  ./scripts/scale-down.sh"
echo "  Auto-stop:      KEDA scales to 0 after 30 min of no requests"
echo ""
