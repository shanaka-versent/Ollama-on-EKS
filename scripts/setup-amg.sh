#!/bin/bash
# Setup AWS Managed Grafana — data sources + dashboards
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Creates a service account in AMG, configures AMP + CloudWatch data sources,
# and imports all dashboards (GPU, Ollama API, Karpenter, FinOps).
#
# Prerequisites:
#   - AMG workspace created by Terraform
#   - AMP workspace with Prometheus remote-writing data
#   - IAM Identity Center (SSO) enabled for AMG access
#
# Usage:
#   ./scripts/setup-amg.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo "========================================"
echo "  Setup AWS Managed Grafana (AMG)"
echo "========================================"
echo ""

export AWS_PROFILE="${AWS_PROFILE:-stax-stax-au1-versent-innovation}"
REGION=$(terraform -chdir="$ROOT_DIR/terraform" output -raw region 2>/dev/null || echo "ap-southeast-2")

# Get workspace IDs from Terraform
AMG_ID=$(terraform -chdir="$ROOT_DIR/terraform" output -raw managed_grafana_url 2>/dev/null | grep -o 'g-[a-z0-9]*' || true)
if [[ -z "$AMG_ID" ]]; then
  AMG_ID=$(aws grafana list-workspaces --region "$REGION" \
    --query 'workspaces[?name==`ollama-grafana`].id' --output text)
fi

AMP_ID=$(aws amp list-workspaces --region "$REGION" \
  --query 'workspaces[?alias==`ollama-prometheus`].workspaceId' --output text)

if [[ -z "$AMG_ID" || -z "$AMP_ID" ]]; then
  echo -e "  ${RED}✗ Could not find AMG or AMP workspace.${NC}"
  echo "    AMG: $AMG_ID  |  AMP: $AMP_ID"
  exit 1
fi

AMG_ENDPOINT="https://$AMG_ID.grafana-workspace.$REGION.amazonaws.com"
AMP_ENDPOINT="https://aps-workspaces.$REGION.amazonaws.com/workspaces/$AMP_ID"

echo -e "  AMG workspace : ${CYAN}$AMG_ID${NC}"
echo -e "  AMP workspace : ${CYAN}$AMP_ID${NC}"
echo -e "  AMG endpoint  : ${CYAN}$AMG_ENDPOINT${NC}"
echo ""

# ============================================================
# Step 1: Create service account + API key
# ============================================================
echo -e "${CYAN}${BOLD}==> Creating Grafana service account...${NC}"

SA_NAME="terraform-setup"

# Check if service account already exists
EXISTING_SA=$(aws grafana list-workspace-service-accounts \
  --workspace-id "$AMG_ID" --region "$REGION" \
  --query "serviceAccounts[?name=='$SA_NAME'].id" --output text 2>/dev/null || true)

if [[ -n "$EXISTING_SA" && "$EXISTING_SA" != "None" ]]; then
  echo -e "  ${YELLOW}⚠${NC} Service account '$SA_NAME' already exists (ID: $EXISTING_SA)"
  SA_ID="$EXISTING_SA"
else
  SA_ID=$(aws grafana create-workspace-service-account \
    --workspace-id "$AMG_ID" --region "$REGION" \
    --name "$SA_NAME" --grafana-role "ADMIN" \
    --query 'id' --output text)
  echo -e "  ${GREEN}✓${NC} Created service account: $SA_ID"
fi

echo -e "${CYAN}${BOLD}==> Creating API token...${NC}"
TOKEN_RESPONSE=$(aws grafana create-workspace-service-account-token \
  --workspace-id "$AMG_ID" --region "$REGION" \
  --service-account-id "$SA_ID" \
  --name "setup-$(date +%s)" --seconds-to-live 3600)

API_KEY=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['serviceAccountToken']['key'])")
echo -e "  ${GREEN}✓${NC} API token created (expires in 1 hour)"

# ============================================================
# Step 2: Create AMP data source
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}==> Configuring AMP data source...${NC}"

DS_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$AMG_ENDPOINT/api/datasources" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Amazon Managed Prometheus\",
    \"type\": \"prometheus\",
    \"url\": \"$AMP_ENDPOINT\",
    \"access\": \"proxy\",
    \"isDefault\": true,
    \"jsonData\": {
      \"httpMethod\": \"POST\",
      \"sigV4Auth\": true,
      \"sigV4AuthType\": \"workspace-iam-role\",
      \"sigV4Region\": \"$REGION\"
    }
  }")

DS_STATUS=$(echo "$DS_RESPONSE" | tail -1)
DS_BODY=$(echo "$DS_RESPONSE" | sed '$d')

if [[ "$DS_STATUS" == "200" || "$DS_STATUS" == "409" ]]; then
  echo -e "  ${GREEN}✓${NC} AMP data source configured"
else
  echo -e "  ${YELLOW}⚠${NC} AMP data source response ($DS_STATUS): $DS_BODY"
fi

# ============================================================
# Step 3: Create CloudWatch data source
# ============================================================
echo -e "${CYAN}${BOLD}==> Configuring CloudWatch data source...${NC}"

CW_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$AMG_ENDPOINT/api/datasources" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"CloudWatch\",
    \"type\": \"cloudwatch\",
    \"access\": \"proxy\",
    \"jsonData\": {
      \"authType\": \"workspace-iam-role\",
      \"defaultRegion\": \"$REGION\"
    }
  }")

CW_STATUS=$(echo "$CW_RESPONSE" | tail -1)
if [[ "$CW_STATUS" == "200" || "$CW_STATUS" == "409" ]]; then
  echo -e "  ${GREEN}✓${NC} CloudWatch data source configured"
else
  echo -e "  ${YELLOW}⚠${NC} CloudWatch data source response ($CW_STATUS)"
fi

# ============================================================
# Step 4: Import dashboards
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}==> Importing dashboards...${NC}"

DASHBOARD_DIR="$ROOT_DIR/terraform/modules/observability/dashboards"

for dashboard_file in "$DASHBOARD_DIR"/*.json; do
  dashboard_name=$(basename "$dashboard_file" .json)
  echo -n "  Importing $dashboard_name..."

  # Wrap dashboard JSON in the import payload
  DASHBOARD_JSON=$(python3 -c "
import json, sys
with open('$dashboard_file') as f:
    dash = json.load(f)
dash['id'] = None  # Let Grafana assign ID
payload = {
    'dashboard': dash,
    'overwrite': True,
    'folderId': 0
}
print(json.dumps(payload))
")

  IMPORT_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$AMG_ENDPOINT/api/dashboards/db" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$DASHBOARD_JSON")

  IMPORT_STATUS=$(echo "$IMPORT_RESPONSE" | tail -1)
  if [[ "$IMPORT_STATUS" == "200" ]]; then
    echo -e " ${GREEN}✓${NC}"
  else
    IMPORT_BODY=$(echo "$IMPORT_RESPONSE" | sed '$d')
    echo -e " ${YELLOW}⚠ ($IMPORT_STATUS)${NC}"
    echo "    $IMPORT_BODY" | head -1
  fi
done

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================"
echo -e "  ${GREEN}${BOLD}AMG setup complete.${NC}"
echo "========================================"
echo ""
echo "  Grafana URL: $AMG_ENDPOINT"
echo "  Login via:   IAM Identity Center (SSO)"
echo ""
echo "  Dashboards:"
echo "    - GPU Metrics       — GPU utilization, temperature, memory, power"
echo "    - Ollama API        — Request latency, throughput, errors"
echo "    - Karpenter         — Node lifecycle, provisioning, spot vs on-demand"
echo "    - FinOps Showback   — Cost breakdown, GPU hours, idle time"
echo ""
echo "  Data sources:"
echo "    - Amazon Managed Prometheus (AMP) — cluster metrics"
echo "    - CloudWatch — AWS service metrics (FinOps)"
echo ""
