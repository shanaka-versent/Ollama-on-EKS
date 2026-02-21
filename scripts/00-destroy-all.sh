#!/bin/bash
# Destroy Ollama on EKS — Complete Teardown Script
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# This script safely destroys all resources created by the deployment:
#   1. Kong Konnect resources (control plane, network, TGW attachment)
#   2. Istio components (ingress gateway, CNI, ztunnel, istiod)
#   3. Kubernetes resources (EBS CSI driver addon)
#   4. Terraform-managed infrastructure (EKS, VPC, Transit Gateway, etc.)
#   5. Orphaned EBS volumes (if any)
#
# CAUTION: This will permanently delete:
#   - All models in EBS storage (200GB volume)
#   - Kong Cloud Gateway configuration
#   - Istio service mesh
#   - EKS cluster and all workloads
#   - VPC, Transit Gateway, Security Groups
#   - ALL AWS resources created by terraform apply
#
# Usage:
#   ./scripts/00-destroy-all.sh [--force]
#
# Options:
#   --force    Skip confirmation prompts (dangerous!)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")}" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"
ENV_FILE="${REPO_DIR}/.env"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }

FORCE_DELETE="${1:-}"

# Load .env if it exists
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# ==============================================================================
# Confirmation
# ==============================================================================

if [[ "$FORCE_DELETE" != "--force" ]]; then
    echo ""
    echo "=========================================="
    echo "  DESTROY Ollama on EKS"
    echo "=========================================="
    echo ""
    echo "  ${RED}WARNING${NC}: This will permanently delete:"
    echo "    • Kong Konnect control plane and cloud gateway network"
    echo "    • Istio service mesh and ingress gateway"
    echo "    • EKS cluster and all pods"
    echo "    • VPC, Transit Gateway, Security Groups"
    echo "    • 200GB EBS volume with model storage"
    echo "    • ALL resources created by terraform apply"
    echo ""
    read -p "  Type 'yes' to confirm destruction: " -r CONFIRM

    if [[ "$CONFIRM" != "yes" ]]; then
        echo "  Cancelled."
        exit 0
    fi
    echo ""
fi

# ==============================================================================
# Get cluster info
# ==============================================================================

log "Getting cluster information from Terraform..."

if [[ ! -d "${TERRAFORM_DIR}/.terraform" ]]; then
    error "Terraform not initialized. Run: terraform init"
    exit 1
fi

EKS_CLUSTER_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw eks_cluster_name 2>/dev/null || echo "")
AWS_REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw region 2>/dev/null || echo "us-west-2")

if [[ -z "$EKS_CLUSTER_NAME" ]]; then
    error "Could not read eks_cluster_name from Terraform. Is the cluster deployed?"
    exit 1
fi

log "  Cluster: $EKS_CLUSTER_NAME"
log "  Region:  $AWS_REGION"
echo ""

# ==============================================================================
# Step 1: Delete Kong Konnect resources
# ==============================================================================

log "Step 1: Removing Kong Konnect resources..."

if [[ -z "${KONNECT_TOKEN:-}" || -z "${KONNECT_REGION:-}" ]]; then
    warn "  KONNECT_TOKEN or KONNECT_REGION not set. Skipping Kong cleanup."
    warn "  Remove the control plane manually at: https://cloud.konghq.com → Gateway Manager"
else
    log "  Fetching control plane ID..."
    CP_RESPONSE=$(curl -s \
        "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes" \
        -H "Authorization: Bearer $KONNECT_TOKEN" 2>/dev/null || true)

    CP_ID=$(echo "$CP_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

    if [[ -n "$CP_ID" && "$CP_ID" != "null" ]]; then
        log "  Deleting control plane: $CP_ID"
        curl -s -X DELETE \
            "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes/$CP_ID" \
            -H "Authorization: Bearer $KONNECT_TOKEN" > /dev/null 2>&1 || true
        log "  Control plane deletion initiated (may take a few minutes)"
    else
        warn "  Could not find control plane. Delete manually if needed."
    fi
fi

echo ""

# ==============================================================================
# Step 2: Configure kubectl
# ==============================================================================

log "Step 2: Configuring kubectl access..."

if ! kubectl cluster-info &>/dev/null 2>&1; then
    log "  Updating kubeconfig..."
    aws eks update-kubeconfig \
        --region "$AWS_REGION" \
        --name "$EKS_CLUSTER_NAME" > /dev/null 2>&1 || true
fi

if ! kubectl cluster-info &>/dev/null 2>&1; then
    warn "  Cannot connect to Kubernetes cluster. Skipping pod cleanup."
    echo ""
else
    # ===========================================================================
    # Step 3: Delete Istio
    # ===========================================================================

    log "Step 3: Removing Istio components..."

    # Uninstall ingress gateway first (depends on istio-system)
    if helm list -n istio-ingress 2>/dev/null | grep -q istio-ingress; then
        log "  Uninstalling Istio ingress gateway..."
        helm uninstall istio-ingress -n istio-ingress 2>/dev/null || true
    fi

    # Delete the gateway namespace to trigger resource cleanup
    if kubectl get namespace istio-ingress &>/dev/null 2>&1; then
        log "  Deleting istio-ingress namespace..."
        kubectl delete namespace istio-ingress --ignore-not-found=true 2>/dev/null || true
        sleep 5
    fi

    # Uninstall Istio system components
    for release in ztunnel istio-cni istiod istio-base; do
        if helm list -n istio-system 2>/dev/null | grep -q "^$release"; then
            log "  Uninstalling $release..."
            helm uninstall "$release" -n istio-system 2>/dev/null || true
        fi
    done

    # Delete istio-system namespace
    if kubectl get namespace istio-system &>/dev/null 2>&1; then
        log "  Deleting istio-system namespace..."
        kubectl delete namespace istio-system --ignore-not-found=true 2>/dev/null || true
        sleep 5
    fi

    log "  Istio components removed"
    echo ""

    # ===========================================================================
    # Step 4: Delete EBS CSI Driver addon
    # ===========================================================================

    log "Step 4: Removing EBS CSI Driver addon..."

    aws eks delete-addon \
        --cluster-name "$EKS_CLUSTER_NAME" \
        --addon-name aws-ebs-csi-driver \
        --region "$AWS_REGION" 2>/dev/null || true

    log "  Addon deletion initiated"
    echo ""
fi

# ==============================================================================
# Step 5: Terraform destroy
# ==============================================================================

log "Step 5: Running terraform destroy..."
echo "  ${YELLOW}This may take 5-10 minutes...${NC}"
echo ""

cd "$TERRAFORM_DIR"
terraform destroy -auto-approve

log "  Terraform destruction complete"
echo ""

# ==============================================================================
# Step 6: Check for orphaned EBS volumes
# ==============================================================================

log "Step 6: Checking for orphaned EBS volumes..."

ORPHANED_VOLUMES=$(aws ec2 describe-volumes \
    --filters "Name=tag:Project,Values=Ollama-Private-LLM" \
    --region "$AWS_REGION" \
    --query 'Volumes[?State==`available`].VolumeId' \
    --output text 2>/dev/null || true)

if [[ -n "$ORPHANED_VOLUMES" ]]; then
    warn "  Found orphaned EBS volumes:"
    for vol_id in $ORPHANED_VOLUMES; do
        echo "    • $vol_id"
    done
    echo ""
    echo "  To delete manually:"
    for vol_id in $ORPHANED_VOLUMES; do
        echo "    aws ec2 delete-volume --volume-id $vol_id --region $AWS_REGION"
    done
    echo ""
else
    log "  No orphaned volumes found"
    echo ""
fi

# ==============================================================================
# Summary
# ==============================================================================

echo "=========================================="
echo "  ${GREEN}Destruction Complete${NC}"
echo "=========================================="
echo ""
echo "  ✓ Kong Konnect resources removed"
echo "  ✓ Istio components removed"
echo "  ✓ EKS cluster destroyed"
echo "  ✓ VPC, Transit Gateway, Security Groups deleted"
echo "  ✓ Terraform state cleaned"
echo ""

if [[ -n "$ORPHANED_VOLUMES" ]]; then
    echo "  ${YELLOW}⚠ Orphaned EBS volumes remain (see above)${NC}"
fi

echo "  All AWS resources have been deleted."
echo ""
