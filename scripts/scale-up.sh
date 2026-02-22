#!/bin/bash
# Scale up GPU node group and start Ollama
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Usage:
#   ./scripts/scale-up.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo "========================================"
echo "  Scale Up — Start Ollama GPU Node"
echo "========================================"
echo ""

export AWS_PROFILE="${AWS_PROFILE:-stax-stax-au1-versent-innovation}"

CLUSTER=$(terraform -chdir="$ROOT_DIR/terraform" output -raw eks_cluster_name)
NODE_GROUP=$(terraform -chdir="$ROOT_DIR/terraform" output -raw gpu_node_group_name)
REGION=$(terraform -chdir="$ROOT_DIR/terraform" output -raw region)

CURRENT_DESIRED=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODE_GROUP" \
  --region "$REGION" \
  --query 'nodegroup.scalingConfig.desiredSize' \
  --output text 2>/dev/null)

echo -e "  Cluster    : ${CYAN}$CLUSTER${NC}"
echo -e "  Node group : ${CYAN}$NODE_GROUP${NC}  (desired: ${YELLOW}$CURRENT_DESIRED${NC})"
echo ""

if [[ "$CURRENT_DESIRED" == "1" ]]; then
  POD_STATUS=$(kubectl get pods -n ollama -l app=ollama \
    --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  if [[ "$POD_STATUS" == "Running" ]]; then
    echo -e "  ${YELLOW}Already running — Ollama pod is $POD_STATUS.${NC}"
    echo ""
    exit 0
  fi
fi

read -r -p "  Scale up now? This will start a GPU node (~\$5.67/hr). [y/N] " confirm
if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
  echo ""
  echo "  Aborted."
  echo ""
  exit 0
fi

echo ""
echo -e "${CYAN}${BOLD}==> Scaling up GPU node group...${NC}"
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODE_GROUP" \
  --scaling-config minSize=0,maxSize=2,desiredSize=1 \
  --region "$REGION" > /dev/null

echo -n "  Waiting for node group ACTIVE"
while true; do
  STATUS=$(aws eks describe-nodegroup \
    --cluster-name "$CLUSTER" \
    --nodegroup-name "$NODE_GROUP" \
    --region "$REGION" \
    --query 'nodegroup.status' --output text 2>/dev/null)
  if [[ "$STATUS" == "ACTIVE" ]]; then echo " — done"; break; fi
  echo -n "."
  sleep 15
done

echo ""
echo -e "${CYAN}${BOLD}==> Waiting for GPU node to join cluster...${NC}"
echo -n "  Waiting for node Ready"
while true; do
  READY_COUNT=$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=$NODE_GROUP" \
    --no-headers 2>/dev/null | grep -v "NotReady\|SchedulingDisabled" | wc -l | tr -d ' ')
  if [[ "$READY_COUNT" -ge 1 ]]; then echo " — done"; break; fi
  echo -n "."
  sleep 15
done

NODE_NAME=$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=$NODE_GROUP" \
  --no-headers 2>/dev/null | grep -v "NotReady\|SchedulingDisabled" | awk '{print $1, $5}')
echo -e "  ${GREEN}✓${NC} Node ready: $NODE_NAME"

echo ""
echo -e "${CYAN}${BOLD}==> Starting Ollama pod...${NC}"
kubectl scale deployment ollama -n ollama --replicas=1

echo -n "  Waiting for pod Running"
while true; do
  POD_STATUS=$(kubectl get pods -n ollama -l app=ollama \
    --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  if [[ "$POD_STATUS" == "Running" ]]; then echo " — done"; break; fi
  echo -n "."
  sleep 10
done

echo ""
echo -e "${CYAN}${BOLD}==> Verifying...${NC}"
FINAL_DESIRED=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODE_GROUP" \
  --region "$REGION" \
  --query 'nodegroup.scalingConfig.desiredSize' \
  --output text)
POD_LINE=$(kubectl get pods -n ollama -l app=ollama \
  --no-headers 2>/dev/null | awk '{print $1, $3}')

echo -e "  Node group desired : ${GREEN}$FINAL_DESIRED${NC}"
echo -e "  Ollama pod         : ${GREEN}$POD_LINE${NC}"

echo ""
echo "========================================"
echo -e "  ${GREEN}${BOLD}Ollama is up and ready.${NC}"
echo "========================================"
echo ""
echo "  Connect:  source claude-switch.sh ollama \\"
echo "              --endpoint https://d509717478.gateways.konggateway.com \\"
echo "              --apikey <your-key>"
echo ""
echo "  Run:      claude --model qwen3-coder:30b"
echo ""
echo "  Stop:     ./scripts/scale-down.sh"
echo ""
