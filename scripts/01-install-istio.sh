#!/bin/bash
# Install Istio Ambient Mesh + Gateway API on EKS
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Installs:
#   1. Gateway API CRDs (v1.2.0)
#   2. Istio Base CRDs
#   3. Istiod (ambient profile)
#   4. Istio CNI
#   5. Ztunnel (L4 mTLS DaemonSet)
#   6. Istio Ingress Gateway
#
# Usage:
#   ./scripts/01-install-istio.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

GATEWAY_API_VERSION="v1.2.0"
ISTIO_VERSION="1.24.2"

echo ""
echo "=============================================="
echo "  Installing Istio Ambient Mesh + Gateway API"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# Verify kubectl connectivity
# ---------------------------------------------------------------------------
if ! kubectl cluster-info &>/dev/null 2>&1; then
    warn "Cannot connect to Kubernetes cluster."
    warn "Run: aws eks update-kubeconfig --region us-west-2 --name <cluster-name>"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Gateway API CRDs
# ---------------------------------------------------------------------------
log "Step 1: Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Istio Helm repo
# ---------------------------------------------------------------------------
log "Step 2: Adding Istio Helm repo..."
helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
helm repo update
echo ""

# ---------------------------------------------------------------------------
# Step 3: Istio Base (CRDs)
# ---------------------------------------------------------------------------
log "Step 3: Installing Istio Base CRDs..."
helm upgrade --install istio-base istio/base \
  -n istio-system --create-namespace \
  --version "${ISTIO_VERSION}" \
  --wait
echo ""

# ---------------------------------------------------------------------------
# Step 4: Istiod (control plane — ambient profile)
# ---------------------------------------------------------------------------
log "Step 4: Installing Istiod (ambient profile)..."
helm upgrade --install istiod istio/istiod \
  -n istio-system \
  --version "${ISTIO_VERSION}" \
  --set profile=ambient \
  --wait
echo ""

# ---------------------------------------------------------------------------
# Step 5: Istio CNI
# ---------------------------------------------------------------------------
log "Step 5: Installing Istio CNI..."
helm upgrade --install istio-cni istio/cni \
  -n istio-system \
  --version "${ISTIO_VERSION}" \
  --set profile=ambient \
  --wait
echo ""

# ---------------------------------------------------------------------------
# Step 6: Ztunnel (L4 mTLS DaemonSet)
# ---------------------------------------------------------------------------
log "Step 6: Installing Ztunnel..."
helm upgrade --install ztunnel istio/ztunnel \
  -n istio-system \
  --version "${ISTIO_VERSION}" \
  --wait
echo ""

# ---------------------------------------------------------------------------
# Step 7: Istio Ingress Gateway
# ---------------------------------------------------------------------------
log "Step 7: Installing Istio Ingress Gateway..."
kubectl create namespace istio-ingress 2>/dev/null || true

# Label namespaces for ambient mesh enrollment
kubectl label namespace istio-ingress istio.io/dataplane-mode=ambient --overwrite
kubectl label namespace ollama istio.io/dataplane-mode=ambient --overwrite

helm upgrade --install istio-ingress istio/gateway \
  -n istio-ingress \
  --version "${ISTIO_VERSION}" \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists \
  --set tolerations[0].effect=NoSchedule \
  --wait
echo ""

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
log "Istio Ambient Mesh installed successfully!"
echo ""
echo "Next steps:"
echo "  1. Generate TLS certs:     ./scripts/02-generate-certs.sh"
echo "  2. Apply Gateway + Routes: kubectl apply -f k8s/gateway.yaml"
echo "                              kubectl apply -f k8s/httproutes.yaml"
echo "  3. Set up Kong Konnect:    ./scripts/03-setup-cloud-gateway.sh"
echo ""
echo "Verify:"
echo "  kubectl get pods -n istio-system"
echo "  kubectl get pods -n istio-ingress"
echo "  kubectl get gateway -n istio-ingress"
echo ""
