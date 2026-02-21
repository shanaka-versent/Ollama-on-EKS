#!/bin/bash
# Ollama on EKS — Full Deploy
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Deploys the complete stack end-to-end:
#   1. terraform init + apply  (VPC, EKS, ArgoCD bootstrap)
#   2. Configure kubectl
#   3. Wait for ArgoCD Wave 1 (namespaces)
#   4. Generate TLS certificates
#   5. Wait for Ollama (Wave 3)
#   6. Set up Kong Konnect Cloud AI Gateway (if credentials in .env)
#
# Usage:
#   ./deploy.sh            # Full deploy (prompts for confirmation)
#   ./deploy.sh --skip-tf  # Skip terraform apply (cluster already exists)
#
# Prerequisites:
#   - .env file exists (copy from .env.example)
#   - awscli, terraform, kubectl, helm installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"
ENV_FILE="${SCRIPT_DIR}/.env"
SKIP_TF="${1:-}"

# Load .env
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "ERROR: .env not found. Copy .env.example and fill in your credentials."
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }
step() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Ollama on EKS — Full Deploy${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ==============================================================================
# Step 1: Terraform
# ==============================================================================

if [[ "$SKIP_TF" == "--skip-tf" ]]; then
    step "Step 1: Skipping Terraform (--skip-tf flag set)"
else
    step "Step 1: Deploying AWS Infrastructure (terraform apply)"
    log "This provisions: VPC, EKS, IAM, LB Controller, Transit Gateway, ArgoCD"
    log "Estimated time: ~20 min"
    echo ""

    cd "$TERRAFORM_DIR"
    terraform init -upgrade -reconfigure 2>/dev/null || terraform init
    terraform apply -auto-approve
    cd "$SCRIPT_DIR"

    log "Terraform complete"
fi

# ==============================================================================
# Steps 2–6: Post-Terraform Setup (delegate to 01-setup.sh)
# ==============================================================================

"${SCRIPT_DIR}/scripts/01-setup.sh"
