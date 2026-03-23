#!/bin/bash
# Scale up Ollama — Karpenter auto-provisions GPU node
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# With EKS Auto Mode + Karpenter: just scale the deployment to 1.
# Karpenter provisions a g5 GPU node automatically (~2-3 min).
# KEDA auto-scaling is paused during startup, then unpaused so
# the 15-min idle timer starts from when the model finishes loading.
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
echo ""
echo -e "${CYAN}${BOLD}==> Pausing KEDA auto-scaling...${NC}"
if kubectl annotate scaledobject ollama-autoscaler -n ollama \
  autoscaling.keda.sh/paused="true" --overwrite 2>/dev/null; then
  echo -e "  ${GREEN}✓${NC} KEDA paused"
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

# Unpause KEDA — model loading created CPU activity, so KEDA has an "active"
# reference point. The 15-min idle timer starts from this point.
echo ""
echo -e "${CYAN}${BOLD}==> Unpausing KEDA auto-scaling...${NC}"
if kubectl annotate scaledobject ollama-autoscaler -n ollama \
  autoscaling.keda.sh/paused- --overwrite 2>/dev/null; then
  echo -e "  ${GREEN}✓${NC} KEDA unpaused — will auto-scale to 0 after 15 min idle"
else
  echo -e "  ${YELLOW}⚠${NC} KEDA ScaledObject not found"
fi

echo ""
echo "========================================"
echo -e "  ${GREEN}${BOLD}Ollama is up and ready.${NC}"
echo "========================================"
echo ""
echo "  Test:"
echo "    kubectl exec -n ollama deploy/ollama -- ollama list"
echo ""
echo "  Stop (manual):  ./scripts/scale-down.sh"
echo "  Auto-stop:      KEDA scales to 0 after 15 min of no requests"
echo ""
