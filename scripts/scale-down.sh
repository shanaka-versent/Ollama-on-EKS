#!/bin/bash
# Scale down Ollama — Karpenter terminates GPU node after 10 min
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# With EKS Auto Mode + Karpenter: just scale the deployment to 0.
# Karpenter detects the empty GPU node and terminates it after 10 min.
# No managed node group operations needed.
#
# Note: KEDA will also auto-scale to 0 after 15 min idle. This script
# is for immediate manual shutdown when you know you're done.
#
# Usage:
#   ./scripts/scale-down.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo "========================================"
echo "  Scale Down — Stop GPU Billing"
echo "========================================"
echo ""

export AWS_PROFILE="${AWS_PROFILE:-stax-stax-au1-versent-innovation}"

REPLICAS=$(kubectl get deployment ollama -n ollama -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
POD_STATUS=$(kubectl get pods -n ollama -l app=ollama \
  --no-headers 2>/dev/null | awk '{print $3}' | head -1)

echo -e "  Ollama replicas : ${YELLOW}$REPLICAS${NC}"
echo -e "  Pod status      : ${YELLOW}${POD_STATUS:-No pods}${NC}"
echo ""

if [[ "$REPLICAS" == "0" ]]; then
  echo -e "  ${YELLOW}Already scaled to 0 — nothing to do.${NC}"
  echo ""
  exit 0
fi

read -r -p "  Scale down now? GPU node will terminate ~10 min after. [y/N] " confirm
if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
  echo ""
  echo "  Aborted."
  echo ""
  exit 0
fi

echo ""
echo -e "${CYAN}${BOLD}==> Scaling Ollama to 0 replicas...${NC}"
kubectl scale deployment ollama -n ollama --replicas=0
echo -e "  ${GREEN}✓${NC} Deployment scaled to 0"

# Unpause KEDA so it can manage auto-scaling going forward
echo ""
echo -e "${CYAN}${BOLD}==> Unpausing KEDA auto-scaling...${NC}"
if kubectl annotate scaledobject ollama-autoscaler -n ollama \
  autoscaling.keda.sh/paused="0" \
  gpu-controller/paused-at- --overwrite 2>/dev/null; then
  echo -e "  ${GREEN}✓${NC} KEDA unpaused"
else
  echo -e "  ${YELLOW}⚠${NC} KEDA ScaledObject not found"
fi

echo ""
echo -e "${CYAN}${BOLD}==> Verifying...${NC}"
sleep 3
FINAL_REPLICAS=$(kubectl get deployment ollama -n ollama -o jsonpath='{.spec.replicas}' 2>/dev/null)
GPU_NODES=$(kubectl get nodeclaims -o wide --no-headers 2>/dev/null | grep "gpu-ollama" | awk '{print $2, $3}')

echo -e "  Ollama replicas  : ${GREEN}$FINAL_REPLICAS${NC}"
if [[ -n "$GPU_NODES" ]]; then
  echo -e "  GPU node         : ${YELLOW}$GPU_NODES${NC} (will terminate in ~10 min)"
else
  echo -e "  GPU node         : ${GREEN}None${NC}"
fi

echo ""
echo "========================================"
echo -e "  ${GREEN}${BOLD}Ollama stopped. GPU node drains in ~10 min.${NC}"
echo "========================================"
echo ""
echo "  To resume:  ./scripts/scale-up.sh"
echo ""
