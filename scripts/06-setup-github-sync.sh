#!/bin/bash
# GitHub Actions Sync Setup — extract infra values, set GitHub secrets, trigger sync
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Run this once after initial deployment, and again whenever the NLB hostname changes.
#
# What it does:
#   1. Reads Konnect credentials from .env
#   2. Reads NLB hostname from the live EKS cluster (via kubectl)
#   3. Updates deck/kong-config.yaml with the real NLB hostname
#   4. Sets KONNECT_TOKEN, KONNECT_REGION, KONNECT_CP_NAME as GitHub Actions secrets
#   5. Commits and pushes deck/kong-config.yaml → triggers the GitHub Actions sync
#
# Prerequisites:
#   - AWS SSO logged in:    aws sso login --profile <your-profile>
#   - gh CLI authenticated: gh auth login
#   - .env with:           KONNECT_TOKEN, KONNECT_REGION, KONNECT_CONTROL_PLANE_NAME
#
# Usage:
#   ./scripts/06-setup-github-sync.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$ROOT_DIR/terraform"
CONFIG_FILE="$ROOT_DIR/deck/kong-config.yaml"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}==>${NC} $*"; }

echo ""
echo "=============================================="
echo "  Kong GitHub Actions Sync Setup"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------
step "Checking prerequisites..."

for cmd in gh aws kubectl terraform deck; do
  if command -v "$cmd" &>/dev/null; then
    log "$cmd found: $(command -v $cmd)"
  else
    error "$cmd not found. Install it first."
  fi
done

gh auth status &>/dev/null || error "gh CLI not authenticated. Run: gh auth login"
log "gh CLI authenticated"

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
step "Loading .env..."

ENV_FILE="$ROOT_DIR/.env"
[[ -f "$ENV_FILE" ]] || error ".env not found at $ENV_FILE"

set -a; source "$ENV_FILE"; set +a

: "${KONNECT_TOKEN:?KONNECT_TOKEN not set in .env}"
: "${KONNECT_REGION:?KONNECT_REGION not set in .env}"

CP_NAME="${KONNECT_CONTROL_PLANE_NAME:-ollama-ai-gateway}"
log "Konnect region:        $KONNECT_REGION"
log "Konnect control plane: $CP_NAME"

# ---------------------------------------------------------------------------
# Update kubeconfig from Terraform outputs
# ---------------------------------------------------------------------------
step "Updating kubeconfig from Terraform outputs..."

REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw region 2>/dev/null) \
  || error "Could not read 'region' from Terraform outputs. Is the cluster deployed?"
CLUSTER_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw eks_cluster_name 2>/dev/null) \
  || error "Could not read 'eks_cluster_name' from Terraform outputs."

log "Cluster: $CLUSTER_NAME  Region: $REGION"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

# ---------------------------------------------------------------------------
# Get NLB hostname from cluster
# ---------------------------------------------------------------------------
step "Fetching NLB hostname from Istio Gateway..."

NLB_HOSTNAME=""
for i in {1..18}; do
  NLB_HOSTNAME=$(kubectl get gateway -n istio-ingress ollama-gateway \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  if [[ -n "$NLB_HOSTNAME" && "$NLB_HOSTNAME" != "<pending>" ]]; then
    log "NLB hostname: $NLB_HOSTNAME"
    break
  fi
  echo -n "  Waiting for NLB... (attempt $i/18)"
  sleep 10
  echo ""
done

[[ -n "$NLB_HOSTNAME" ]] || error "Could not get NLB hostname. Is the Gateway deployed? Check: kubectl get gateway -n istio-ingress"

# ---------------------------------------------------------------------------
# Update deck/kong-config.yaml with real NLB hostname
# ---------------------------------------------------------------------------
step "Updating deck/kong-config.yaml with NLB hostname..."

if grep -q "<YOUR_NLB_DNS>" "$CONFIG_FILE"; then
  sed -i.bak "s|<YOUR_NLB_DNS>|${NLB_HOSTNAME}|g" "$CONFIG_FILE"
  rm -f "${CONFIG_FILE}.bak"
  log "Replaced <YOUR_NLB_DNS> → $NLB_HOSTNAME"
elif grep -q "$NLB_HOSTNAME" "$CONFIG_FILE"; then
  log "NLB hostname already set in kong-config.yaml — no change needed"
else
  warn "Could not find <YOUR_NLB_DNS> placeholder. Current URLs in config:"
  grep "url:" "$CONFIG_FILE" || true
  warn "Update deck/kong-config.yaml manually if the hostname is wrong."
fi

# ---------------------------------------------------------------------------
# Set GitHub Actions secrets
# ---------------------------------------------------------------------------
step "Setting GitHub Actions secrets..."

REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) \
  || error "Could not determine GitHub repo. Make sure you're in the repo directory."
log "Repository: $REPO"

gh secret set KONNECT_TOKEN  --body "$KONNECT_TOKEN"  --repo "$REPO"
log "Set KONNECT_TOKEN"

gh secret set KONNECT_REGION --body "$KONNECT_REGION" --repo "$REPO"
log "Set KONNECT_REGION"

gh secret set KONNECT_CP_NAME --body "$CP_NAME"       --repo "$REPO"
log "Set KONNECT_CP_NAME"

# ---------------------------------------------------------------------------
# Commit and push to trigger GitHub Actions
# ---------------------------------------------------------------------------
step "Committing deck/kong-config.yaml and pushing to trigger sync..."

cd "$ROOT_DIR"
if git diff --quiet "$CONFIG_FILE"; then
  log "deck/kong-config.yaml unchanged — triggering workflow manually..."
  gh workflow run kong-sync.yml --repo "$REPO" --ref main 2>/dev/null \
    || warn "Manual trigger failed. Push a change to deck/kong-config.yaml to trigger the workflow."
else
  git add "$CONFIG_FILE"
  git commit -m "chore: update NLB hostname in kong-config.yaml"
  git push origin main
  log "Pushed — GitHub Actions sync will start shortly"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  Done!"
echo "=============================================="
echo ""
echo "  GitHub secrets set:  KONNECT_TOKEN, KONNECT_REGION, KONNECT_CP_NAME"
echo "  NLB hostname:        $NLB_HOSTNAME"
echo ""
echo "  Monitor the sync:"
echo "    gh run watch --repo $REPO"
echo ""
echo "  Future pushes to deck/kong-config.yaml will auto-sync to Konnect."
echo ""
