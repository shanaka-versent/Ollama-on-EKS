#!/bin/bash
# Setup Kong Konnect Dedicated Cloud AI Gateway
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Creates a Konnect control plane with Dedicated Cloud Gateway,
# provisions the cloud gateway network, and configures Transit Gateway
# attachment for private connectivity to EKS Ollama service.
#
# Prerequisites:
#   1. A Konnect Personal Access Token (kpat_xxx)
#   2. EKS cluster deployed with Terraform (for Transit Gateway ID)
#   3. .env file with KONNECT_REGION and KONNECT_TOKEN
#
# Usage:
#   ./scripts/03-setup-cloud-gateway.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }

CP_NAME="${KONNECT_CONTROL_PLANE_NAME:-ollama-ai-gateway}"
DCGW_NETWORK_NAME="ollama-eks-network"
DCGW_CIDR="192.168.0.0/16"
KONG_GW_VERSION="3.9"

# AWS region for Kong Cloud Gateway network
KONG_AWS_REGION="${KONG_AWS_REGION:-us-west-2}"
# Availability zones (must match your EKS region)
KONG_AZS="${KONG_AZS:-usw2-az1,usw2-az2}"

# ---------------------------------------------------------------------------
# Auto-populate Transit Gateway values from Terraform outputs
# ---------------------------------------------------------------------------
populate_from_terraform() {
    local tf_dir="${SCRIPT_DIR}/../terraform"

    if [[ -d "${tf_dir}/.terraform" ]]; then
        log "Reading Transit Gateway values from Terraform outputs..."
        if [[ -z "${TRANSIT_GATEWAY_ID:-}" ]]; then
            TRANSIT_GATEWAY_ID=$(terraform -chdir="$tf_dir" output -raw transit_gateway_id 2>/dev/null || true)
        fi
        if [[ -z "${RAM_SHARE_ARN:-}" ]]; then
            RAM_SHARE_ARN=$(terraform -chdir="$tf_dir" output -raw ram_share_arn 2>/dev/null || true)
        fi
        if [[ -z "${EKS_VPC_CIDR:-}" ]]; then
            EKS_VPC_CIDR=$(terraform -chdir="$tf_dir" output -raw vpc_cidr 2>/dev/null || true)
        fi
    fi
}

# ---------------------------------------------------------------------------
# Validate environment variables
# ---------------------------------------------------------------------------
validate_env() {
    local missing=false

    if [[ -z "${KONNECT_REGION:-}" ]]; then
        error "KONNECT_REGION not set (e.g., us, eu, au)"
        missing=true
    fi
    if [[ -z "${KONNECT_TOKEN:-}" ]]; then
        error "KONNECT_TOKEN not set (Personal Access Token from Konnect)"
        missing=true
    fi

    if [[ "$missing" == true ]]; then
        echo ""
        echo "Usage:"
        echo "  1. Copy .env.example to .env and set KONNECT_REGION and KONNECT_TOKEN"
        echo "     cp .env.example .env"
        echo ""
        echo "  2. Run this script (Transit Gateway values are auto-read from Terraform):"
        echo "     ./scripts/03-setup-cloud-gateway.sh"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Create Control Plane (idempotent — reuses existing on 409)
# ---------------------------------------------------------------------------
create_control_plane() {
    log "Step 1: Creating Konnect control plane: ${CP_NAME}"

    if [[ -n "${CONTROL_PLANE_ID:-}" ]]; then
        log "  Using existing control plane: ${CONTROL_PLANE_ID}"
        return
    fi

    CP_RESPONSE=$(curl -s -X POST \
        "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"${CP_NAME}\",
            \"cluster_type\": \"CLUSTER_TYPE_CONTROL_PLANE\",
            \"cloud_gateway\": true,
            \"labels\": {
                \"env\": \"dev\",
                \"type\": \"cloud-ai-gateway\",
                \"managed-by\": \"script\",
                \"purpose\": \"ollama-llm\"
            }
        }")

    # 409 = control plane already exists — fetch it instead of failing
    if [[ "$(echo "$CP_RESPONSE" | jq -r '.status // empty')" == "409" ]]; then
        log "  Control plane already exists — fetching existing ID..."
        EXISTING_CP=$(curl -s \
            "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes" \
            -H "Authorization: Bearer $KONNECT_TOKEN")
        CONTROL_PLANE_ID=$(echo "$EXISTING_CP" | jq -r \
            --arg name "$CP_NAME" '.data[] | select(.name == $name) | .id' | head -1)
    else
        CONTROL_PLANE_ID=$(echo "$CP_RESPONSE" | jq -r '.id')
    fi

    if [[ -z "$CONTROL_PLANE_ID" || "$CONTROL_PLANE_ID" == "null" ]]; then
        error "Failed to create or find control plane"
        error "Response: $CP_RESPONSE"
        exit 1
    fi

    log "  Control Plane ID: ${CONTROL_PLANE_ID}"
}

# ---------------------------------------------------------------------------
# Step 2: Create Cloud Gateway Network
# ---------------------------------------------------------------------------
create_network() {
    log "Step 2: Creating Cloud Gateway Network: ${DCGW_NETWORK_NAME}"

    PROVIDER_ACCOUNTS=$(curl -s \
        "https://global.api.konghq.com/v2/cloud-gateways/provider-accounts" \
        -H "Authorization: Bearer $KONNECT_TOKEN")

    PROVIDER_ACCOUNT_ID=$(echo "$PROVIDER_ACCOUNTS" | jq -r \
        '.data[] | select(.provider == "aws") | .id' | head -1)

    if [[ -z "$PROVIDER_ACCOUNT_ID" || "$PROVIDER_ACCOUNT_ID" == "null" ]]; then
        warn "Could not find AWS provider account."
        warn "You may need to create the network manually in Konnect UI."
        return
    fi

    # Convert comma-separated AZs to JSON array
    AZ_JSON=$(echo "$KONG_AZS" | tr ',' '\n' | jq -R . | jq -s .)

    NETWORK_RESPONSE=$(curl -s -X POST \
        "https://global.api.konghq.com/v2/cloud-gateways/networks" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"${DCGW_NETWORK_NAME}\",
            \"cloud_gateway_provider_account_id\": \"${PROVIDER_ACCOUNT_ID}\",
            \"region\": \"${KONG_AWS_REGION}\",
            \"availability_zones\": ${AZ_JSON},
            \"cidr_block\": \"${DCGW_CIDR}\"
        }")

    # On any error (409 conflict or 403 quota exceeded), fall back to listing existing networks
    RESPONSE_STATUS=$(echo "$NETWORK_RESPONSE" | jq -r '.status // empty')
    if [[ -n "$RESPONSE_STATUS" ]]; then
        log "  Network creation returned status ${RESPONSE_STATUS} — fetching existing network by name..."
        EXISTING_NET=$(curl -s \
            "https://global.api.konghq.com/v2/cloud-gateways/networks" \
            -H "Authorization: Bearer $KONNECT_TOKEN")
        NETWORK_ID=$(echo "$EXISTING_NET" | jq -r \
            --arg name "$DCGW_NETWORK_NAME" '.data[] | select(.name == $name) | .id' | head -1)
    else
        NETWORK_ID=$(echo "$NETWORK_RESPONSE" | jq -r '.id')
    fi

    if [[ -z "$NETWORK_ID" || "$NETWORK_ID" == "null" ]]; then
        error "Failed to create or find network"
        error "Response: $NETWORK_RESPONSE"
        warn "You may need to create this via Konnect UI instead."
        return
    fi

    log "  Network ID: ${NETWORK_ID}"
    log "  Network provisioning takes ~30 minutes."
}

# ---------------------------------------------------------------------------
# Step 3: Create Data Plane Group Configuration
# ---------------------------------------------------------------------------
create_dp_group() {
    log "Step 3: Creating Data Plane Group Configuration"

    if [[ -z "${NETWORK_ID:-}" ]]; then
        warn "Network ID not available. Create data plane group manually in Konnect UI."
        return
    fi

    CONFIG_RESPONSE=$(curl -s -X PUT \
        "https://global.api.konghq.com/v2/cloud-gateways/configurations" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"control_plane_id\": \"${CONTROL_PLANE_ID}\",
            \"version\": \"${KONG_GW_VERSION}\",
            \"control_plane_geo\": \"${KONNECT_REGION}\",
            \"dataplane_groups\": [{
                \"provider\": \"aws\",
                \"region\": \"${KONG_AWS_REGION}\",
                \"cloud_gateway_network_id\": \"${NETWORK_ID}\",
                \"autoscale\": {
                    \"kind\": \"autopilot\",
                    \"base_rps\": 100
                }
            }]
        }")

    CONFIG_ID=$(echo "$CONFIG_RESPONSE" | jq -r '.id // .message // "unknown"')
    log "  Configuration: $CONFIG_ID"
}

# ---------------------------------------------------------------------------
# Step 4: Share RAM with Kong's AWS account
# ---------------------------------------------------------------------------
share_ram_with_kong() {
    if [[ -z "${RAM_SHARE_ARN:-}" ]]; then
        warn "RAM_SHARE_ARN not set. Skipping RAM principal association."
        return
    fi

    log "Step 4: Sharing Transit Gateway with Kong's AWS account via RAM"

    KONG_AWS_ACCOUNT_ID=$(curl -s \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        "https://global.api.konghq.com/v2/cloud-gateways/provider-accounts" \
        | jq -r '.data[] | select(.provider == "aws") | .provider_account_id' | head -1)

    if [[ -z "$KONG_AWS_ACCOUNT_ID" || "$KONG_AWS_ACCOUNT_ID" == "null" ]]; then
        warn "Could not determine Kong's AWS account ID."
        warn "Add Kong's AWS account as a RAM principal manually."
        return
    fi

    log "  Kong's AWS Account ID: ${KONG_AWS_ACCOUNT_ID}"

    EXISTING=$(aws ram get-resource-share-associations \
        --association-type PRINCIPAL \
        --resource-share-arns "${RAM_SHARE_ARN}" \
        --query "resourceShareAssociations[?associatedEntity=='${KONG_AWS_ACCOUNT_ID}'].status" \
        --output text 2>/dev/null || true)

    if [[ "$EXISTING" == "ASSOCIATED" ]]; then
        log "  RAM principal already ASSOCIATED"
        return
    elif [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
        log "  RAM principal status: ${EXISTING} — waiting for ASSOCIATED..."
    else
        log "  Associating Kong's AWS account with RAM share..."
        if ! aws ram associate-resource-share \
            --resource-share-arn "${RAM_SHARE_ARN}" \
            --principals "${KONG_AWS_ACCOUNT_ID}" > /dev/null 2>&1; then
            warn "  RAM associate-resource-share failed. Check AWS permissions and RAM share ARN."
            warn "  Manual fix: aws ram associate-resource-share --resource-share-arn ${RAM_SHARE_ARN} --principals ${KONG_AWS_ACCOUNT_ID}"
            return
        fi
        log "  RAM associate command sent — waiting for ASSOCIATED status..."
    fi

    # Wait up to 3 min for the association to complete
    # External accounts need to accept the invitation; Kong's Konnect automation does this
    local waited=0
    while [[ $waited -lt 180 ]]; do
        STATUS=$(aws ram get-resource-share-associations \
            --association-type PRINCIPAL \
            --resource-share-arns "${RAM_SHARE_ARN}" \
            --query "resourceShareAssociations[?associatedEntity=='${KONG_AWS_ACCOUNT_ID}'].status" \
            --output text 2>/dev/null || true)
        if [[ "$STATUS" == "ASSOCIATED" ]]; then
            log "  RAM share ASSOCIATED with Kong's AWS account"
            return
        fi
        log "  RAM status: ${STATUS} (waited ${waited}s / 180s — Kong accepting invitation)"
        sleep 15
        waited=$((waited + 15))
    done

    warn "  RAM association did not reach ASSOCIATED within 3 min. Kong may accept later."
    warn "  The TGW attachment will be created now; Konnect will retry once RAM is accepted."
}

# ---------------------------------------------------------------------------
# Step 5: Wait for network and attach Transit Gateway
# ---------------------------------------------------------------------------
attach_transit_gateway() {
    if [[ -z "${TRANSIT_GATEWAY_ID:-}" || -z "${RAM_SHARE_ARN:-}" || -z "${EKS_VPC_CIDR:-}" ]]; then
        warn "Transit Gateway variables not set. Skipping TGW attachment."
        return
    fi

    if [[ -z "${NETWORK_ID:-}" ]]; then
        warn "Network ID not available. Attach Transit Gateway manually in Konnect UI."
        return
    fi

    log "Step 5: Waiting for Cloud Gateway Network to be ready..."
    local max_wait=2400
    local interval=30
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        NETWORK_STATE=$(curl -s \
            -H "Authorization: Bearer $KONNECT_TOKEN" \
            "https://global.api.konghq.com/v2/cloud-gateways/networks/${NETWORK_ID}" \
            | jq -r '.state')

        if [[ "$NETWORK_STATE" == "ready" ]]; then
            log "  Network is ready"
            break
        fi

        log "  Network state: ${NETWORK_STATE} (waited ${waited}s / ${max_wait}s)"
        sleep "$interval"
        waited=$((waited + interval))
    done

    if [[ "$NETWORK_STATE" != "ready" ]]; then
        warn "Network did not reach 'ready' state within ${max_wait}s."
        return
    fi

    log "  Attaching Transit Gateway to Cloud Gateway Network"

    TGW_RESPONSE=$(curl -s -X POST \
        "https://global.api.konghq.com/v2/cloud-gateways/networks/${NETWORK_ID}/transit-gateways" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"ollama-eks-transit-gateway\",
            \"cidr_blocks\": [\"${EKS_VPC_CIDR}\"],
            \"transit_gateway_attachment_config\": {
                \"kind\": \"aws-transit-gateway-attachment\",
                \"transit_gateway_id\": \"${TRANSIT_GATEWAY_ID}\",
                \"ram_share_arn\": \"${RAM_SHARE_ARN}\"
            }
        }")

    TGW_ATT_ID=$(echo "$TGW_RESPONSE" | jq -r '.id // .message // "unknown"')
    log "  Transit Gateway attachment: $TGW_ATT_ID"

    if [[ "$TGW_ATT_ID" == "unknown" || "$TGW_ATT_ID" == "null" ]]; then
        warn "TGW attachment may have failed. Check Konnect UI."
        return
    fi

    log "  Waiting for attachment to complete..."
    local tgw_waited=0
    local tgw_max=600
    while [[ $tgw_waited -lt $tgw_max ]]; do
        TGW_STATE=$(curl -s \
            -H "Authorization: Bearer $KONNECT_TOKEN" \
            "https://global.api.konghq.com/v2/cloud-gateways/networks/${NETWORK_ID}/transit-gateways/${TGW_ATT_ID}" \
            | jq -r '.state')

        if [[ "$TGW_STATE" == "ready" ]]; then
            log "  Transit Gateway attachment is ready!"
            return
        fi

        log "  TGW attachment state: ${TGW_STATE} (waited ${tgw_waited}s)"
        sleep 30
        tgw_waited=$((tgw_waited + 30))
    done

    warn "TGW attachment did not reach 'ready' within ${tgw_max}s."
    warn "Check Konnect UI: Gateway Manager → Cloud Gateways"
}

# ---------------------------------------------------------------------------
# Print next steps
# ---------------------------------------------------------------------------
show_next_steps() {
    echo ""
    echo "=========================================="
    echo "  Cloud AI Gateway Setup Summary"
    echo "=========================================="
    echo ""
    echo "Control Plane:    ${CP_NAME}"
    echo "Control Plane ID: ${CONTROL_PLANE_ID:-'N/A'}"
    echo "Network ID:       ${NETWORK_ID:-'N/A'}"
    echo "Region:           ${KONNECT_REGION}"
    echo ""
    echo "Next steps:"
    echo "  1. Get the Istio Gateway NLB DNS:"
    echo "     ./scripts/04-post-setup.sh"
    echo ""
    echo "  2. Update deck/kong.yaml with the NLB hostname, then sync:"
    echo "     deck gateway sync deck/kong.yaml \\"
    echo "       --konnect-addr https://\${KONNECT_REGION}.api.konghq.com \\"
    echo "       --konnect-token \$KONNECT_TOKEN \\"
    echo "       --konnect-control-plane-name ${CP_NAME}"
    echo ""
    echo "  3. Get your Kong proxy URL from Konnect UI:"
    echo "     https://cloud.konghq.com → Gateway Manager → Data Plane Nodes"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Kong Konnect Dedicated Cloud AI Gateway"
    echo "  for Ollama on EKS"
    echo "=============================================="
    echo ""

    populate_from_terraform
    validate_env
    create_control_plane
    create_network
    create_dp_group
    share_ram_with_kong
    attach_transit_gateway
    show_next_steps
}

main "$@"
