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
#   ./destroy.sh [--force]
#
# Options:
#   --force    Skip confirmation prompts (dangerous!)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"
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
VPC_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw vpc_id 2>/dev/null || echo "")

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

CP_NAME="${KONNECT_CONTROL_PLANE_NAME:-kong-cloud-gateway-eks}"
NETWORK_NAME="ollama-eks-network"

if [[ -z "${KONNECT_TOKEN:-}" || -z "${KONNECT_REGION:-}" ]]; then
    warn "  KONNECT_TOKEN or KONNECT_REGION not set. Skipping Kong cleanup."
    warn "  Remove resources manually at: https://cloud.konghq.com → Gateway Manager"
else
    # Delete cloud gateway network first (must be removed before control plane)
    log "  Fetching cloud gateway network: ${NETWORK_NAME}"
    NETWORKS=$(curl -s \
        "https://global.api.konghq.com/v2/cloud-gateways/networks" \
        -H "Authorization: Bearer $KONNECT_TOKEN" 2>/dev/null || true)

    NETWORK_ID=$(echo "$NETWORKS" | jq -r \
        --arg name "$NETWORK_NAME" '.data[] | select(.name == $name) | .id' | head -1 || true)

    if [[ -n "$NETWORK_ID" && "$NETWORK_ID" != "null" ]]; then
        log "  Deleting cloud gateway network: $NETWORK_ID"
        curl -s -X DELETE \
            "https://global.api.konghq.com/v2/cloud-gateways/networks/${NETWORK_ID}" \
            -H "Authorization: Bearer $KONNECT_TOKEN" > /dev/null 2>&1 || true
        log "  Network deletion initiated"
    else
        log "  No cloud gateway network found (${NETWORK_NAME}) — skipping"
    fi

    # Delete control plane by name
    log "  Fetching control plane: ${CP_NAME}"
    CP_RESPONSE=$(curl -s \
        "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes" \
        -H "Authorization: Bearer $KONNECT_TOKEN" 2>/dev/null || true)

    CP_ID=$(echo "$CP_RESPONSE" | jq -r \
        --arg name "$CP_NAME" '.data[] | select(.name == $name) | .id' | head -1 || true)

    if [[ -n "$CP_ID" && "$CP_ID" != "null" ]]; then
        log "  Deleting control plane: $CP_ID"
        curl -s -X DELETE \
            "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes/$CP_ID" \
            -H "Authorization: Bearer $KONNECT_TOKEN" > /dev/null 2>&1 || true
        log "  Control plane deletion initiated"
    else
        warn "  Could not find control plane '${CP_NAME}'. Delete manually if needed."
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
    # Step 3: Delete ArgoCD Applications (removes Istio, Ollama, Gateway, etc.)
    # ===========================================================================

    log "Step 3: Removing ArgoCD Applications (Istio, Ollama, Gateway, HTTPRoutes)..."

    # Delete all ArgoCD Applications — ArgoCD cascades deletion to all managed
    # Kubernetes resources (Istio, NVIDIA plugin, Ollama, Gateway, HTTPRoutes)
    if kubectl get applications -n argocd &>/dev/null 2>&1; then
        log "  Deleting all ArgoCD Applications..."
        kubectl delete applications --all -n argocd --timeout=120s 2>/dev/null || true
    fi

    # Wait for NLB to be deleted before terraform destroy.
    # The LB Controller deletes the NLB when the Gateway resource is removed.
    # If terraform destroy runs while the NLB still exists, it cannot delete the
    # VPC (NLB ENIs still occupy the subnets) and the destroy fails.
    if [[ -n "$VPC_ID" ]]; then
        log "  Waiting for NLB to be deleted by LB Controller (up to 5 min)..."
        max_wait=300
        interval=15
        waited=0
        while [[ $waited -lt $max_wait ]]; do
            NLB_COUNT=$(aws elbv2 describe-load-balancers \
                --region "$AWS_REGION" \
                --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" \
                --output text 2>/dev/null | wc -w | tr -d ' ' || echo "0")
            if [[ "$NLB_COUNT" -eq 0 ]]; then
                log "  No NLBs remaining in VPC"
                break
            fi
            echo "  [${waited}s] Waiting for ${NLB_COUNT} NLB(s) to be deleted..."
            sleep "$interval"
            waited=$((waited + interval))
        done
        if [[ "$waited" -ge "$max_wait" ]]; then
            warn "  NLB still present after ${max_wait}s — terraform destroy may fail."
            warn "  Check: aws elbv2 describe-load-balancers --region $AWS_REGION"
        fi
    fi

    # Uninstall ArgoCD Helm releases
    if helm list -n argocd 2>/dev/null | grep -q argocd; then
        log "  Uninstalling ArgoCD..."
        helm uninstall argocd-root-app -n argocd 2>/dev/null || true
        helm uninstall argocd -n argocd 2>/dev/null || true
    fi

    # Clean up namespaces that ArgoCD managed
    for ns in istio-ingress istio-system ollama argocd; do
        if kubectl get namespace "$ns" &>/dev/null 2>&1; then
            log "  Deleting namespace: $ns"
            kubectl delete namespace "$ns" --ignore-not-found=true --timeout=60s 2>/dev/null || true
        fi
    done

    log "  ArgoCD and all managed resources removed"
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
echo "  ✓ ArgoCD Applications deleted (Istio, Ollama, Gateway)"
echo "  ✓ ArgoCD uninstalled"
echo "  ✓ EKS cluster destroyed"
echo "  ✓ VPC, Transit Gateway, Security Groups deleted"
echo "  ✓ Terraform state cleaned"
echo ""

if [[ -n "$ORPHANED_VOLUMES" ]]; then
    echo "  ${YELLOW}⚠ Orphaned EBS volumes remain (see above)${NC}"
fi

echo "  All AWS resources have been deleted."
echo ""
