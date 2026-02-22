#!/bin/bash
# Scale down GPU node group to zero — stops GPU billing
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Usage:
#   ./scripts/scale-down.sh

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
echo "  Scale Down — Stop GPU Billing"
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

POD_STATUS=$(kubectl get deployment ollama -n ollama \
  --no-headers 2>/dev/null | awk '{print $2}')

echo -e "  Cluster    : ${CYAN}$CLUSTER${NC}"
echo -e "  Node group : ${CYAN}$NODE_GROUP${NC}  (desired: ${YELLOW}$CURRENT_DESIRED${NC})"
echo -e "  Ollama pod : ${CYAN}$POD_STATUS${NC}"
echo ""

if [[ "$CURRENT_DESIRED" == "0" ]]; then
  echo -e "  ${YELLOW}Already scaled to 0 — nothing to do.${NC}"
  echo ""
  exit 0
fi

read -r -p "  Scale down now? This will stop the GPU node and end billing. [y/N] " confirm
if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
  echo ""
  echo "  Aborted."
  echo ""
  exit 0
fi

echo ""
echo -e "${CYAN}${BOLD}==> Stopping Ollama pod...${NC}"
kubectl scale deployment ollama -n ollama --replicas=0
echo -e "  ${GREEN}✓${NC} Deployment scaled to 0"

echo ""
echo -e "${CYAN}${BOLD}==> Scaling down GPU node group...${NC}"
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODE_GROUP" \
  --scaling-config minSize=0,maxSize=2,desiredSize=0 \
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
echo -e "${CYAN}${BOLD}==> Verifying...${NC}"
FINAL_DESIRED=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODE_GROUP" \
  --region "$REGION" \
  --query 'nodegroup.scalingConfig.desiredSize' \
  --output text)
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep "g5\." | wc -l | tr -d ' ')
DEPLOY_STATUS=$(kubectl get deployment ollama -n ollama --no-headers 2>/dev/null | awk '{print $2}')

echo -e "  Node group desired   : ${GREEN}$FINAL_DESIRED${NC}"
echo -e "  GPU nodes in cluster : ${GREEN}$NODE_COUNT${NC}"
echo -e "  Ollama deployment    : ${GREEN}$DEPLOY_STATUS${NC}"

echo ""
echo "========================================"
echo -e "  ${GREEN}${BOLD}GPU node scaled down — billing stopped.${NC}"
echo "========================================"
echo ""
echo "  To resume:  ./scripts/scale-up.sh"
echo ""
