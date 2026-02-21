#!/bin/bash
# Generate TLS Certificates for Istio Gateway
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Generates self-signed TLS certificates and creates the Kubernetes TLS
# secret for the Istio Gateway HTTPS listener (port 443).
#
# Usage:
#   ./scripts/02-generate-certs.sh [domain]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/../certs"
DOMAIN="${1:-ollama-gateway.local}"
GATEWAY_NAME="ollama-gateway"
NAMESPACE="istio-ingress"
SECRET_NAME="istio-gateway-tls"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo ""
echo "=== Generating TLS Certificates for Istio Gateway ==="
echo ""
echo "Domain: ${DOMAIN}"
echo "Output: ${CERTS_DIR}"
echo ""

mkdir -p "${CERTS_DIR}"

# ---------------------------------------------------------------------------
# Step 1: Generate CA
# ---------------------------------------------------------------------------
log "Generating CA private key..."
openssl genrsa -out "${CERTS_DIR}/ca.key" 4096

log "Generating CA certificate..."
openssl req -new -x509 -days 365 -key "${CERTS_DIR}/ca.key" \
  -out "${CERTS_DIR}/ca.crt" \
  -subj "/C=AU/ST=NSW/L=Sydney/O=Ollama-EKS/CN=Ollama EKS CA"

# ---------------------------------------------------------------------------
# Step 2: Generate server certificate
# ---------------------------------------------------------------------------
log "Generating server private key..."
openssl genrsa -out "${CERTS_DIR}/server.key" 2048

cat > "${CERTS_DIR}/server.cnf" << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = AU
ST = NSW
L = Sydney
O = Ollama-EKS
CN = ${DOMAIN}

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = *.${DOMAIN}
DNS.3 = localhost
DNS.4 = ${GATEWAY_NAME}-istio.${NAMESPACE}.svc.cluster.local
IP.1 = 127.0.0.1
EOF

log "Generating server CSR..."
openssl req -new -key "${CERTS_DIR}/server.key" \
  -out "${CERTS_DIR}/server.csr" \
  -config "${CERTS_DIR}/server.cnf"

log "Signing server certificate with CA..."
openssl x509 -req -days 365 \
  -in "${CERTS_DIR}/server.csr" \
  -CA "${CERTS_DIR}/ca.crt" \
  -CAkey "${CERTS_DIR}/ca.key" \
  -CAcreateserial \
  -out "${CERTS_DIR}/server.crt" \
  -extensions req_ext \
  -extfile "${CERTS_DIR}/server.cnf"

rm -f "${CERTS_DIR}/server.csr" "${CERTS_DIR}/server.cnf" "${CERTS_DIR}/ca.srl"

echo ""
log "Certificates generated:"
echo "  CA Certificate:     ${CERTS_DIR}/ca.crt"
echo "  Server Certificate: ${CERTS_DIR}/server.crt"
echo "  Server Key:         ${CERTS_DIR}/server.key"

# ---------------------------------------------------------------------------
# Step 3: Create Kubernetes TLS secret
# ---------------------------------------------------------------------------
echo ""

if ! kubectl cluster-info &>/dev/null 2>&1; then
    warn "Cannot connect to Kubernetes cluster. Create the secret manually:"
    echo "  kubectl create secret tls ${SECRET_NAME} \\"
    echo "    --cert=${CERTS_DIR}/server.crt \\"
    echo "    --key=${CERTS_DIR}/server.key \\"
    echo "    -n ${NAMESPACE}"
    exit 0
fi

kubectl create namespace "${NAMESPACE}" 2>/dev/null || true

if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    log "Replacing existing TLS secret..."
    kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}"
fi

log "Creating TLS secret '${SECRET_NAME}' in namespace '${NAMESPACE}'..."
kubectl create secret tls "${SECRET_NAME}" \
  --cert="${CERTS_DIR}/server.crt" \
  --key="${CERTS_DIR}/server.key" \
  -n "${NAMESPACE}"

echo ""
log "TLS secret created. Istio Gateway HTTPS listener (port 443) is ready."
echo ""

# ---------------------------------------------------------------------------
# Step 4: Patch gateway Deployment toleration
# ---------------------------------------------------------------------------
# All cluster nodes carry taints (CriticalAddonsOnly or nvidia.com/gpu).
# Istio auto-generates the gateway Deployment without tolerations, causing the
# pod to be stuck Pending. Patch it here after the Gateway is deployed.
# Istio preserves user-added pod spec fields (tolerations) across reconciliations.
log "Patching Istio gateway Deployment with CriticalAddonsOnly toleration..."
retry=0
while [[ $retry -lt 10 ]]; do
    if kubectl get deployment ollama-gateway-istio -n "${NAMESPACE}" &>/dev/null 2>&1; then
        kubectl patch deployment ollama-gateway-istio -n "${NAMESPACE}" --type='json' \
            -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"CriticalAddonsOnly","operator":"Exists","effect":"NoSchedule"}]}]' \
            2>/dev/null && break
    fi
    log "  Gateway Deployment not ready yet, retrying in 15s... ($((retry+1))/10)"
    sleep 15
    retry=$((retry + 1))
done
log "  Gateway Deployment patched — pod will schedule on system nodes."
echo ""
