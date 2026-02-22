#!/bin/bash
# Kong Config Sync — sync deck/kong-config.yaml and deck/kong-consumers.yaml to Konnect
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Syncs Kong Gateway configuration (services, routes, plugins) and optionally
# consumer credentials to Kong Konnect Cloud Gateway.
#
# Prerequisites:
#   - .env file with KONNECT_TOKEN, KONNECT_REGION, KONNECT_CONTROL_PLANE_NAME
#   - decK installed: brew install deck
#   - deck/kong-config.yaml (committed, no secrets)
#   - deck/kong-consumers.yaml (gitignored, contains API keys)
#     Copy from template: cp deck/kong-consumers.yaml.sample deck/kong-consumers.yaml
#
# Usage:
#   ./scripts/05-sync-kong-config.sh              # sync config + consumers
#   ./scripts/05-sync-kong-config.sh --config-only # sync config only (no consumer changes)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CONFIG_ONLY=false
if [[ "${1:-}" == "--config-only" ]]; then
  CONFIG_ONLY=true
fi

# Load environment variables
ENV_FILE="$ROOT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  echo "       Create it with: KONNECT_TOKEN, KONNECT_REGION, KONNECT_CONTROL_PLANE_NAME"
  exit 1
fi
source "$ENV_FILE"

: "${KONNECT_TOKEN:?ERROR: KONNECT_TOKEN not set in .env}"
: "${KONNECT_REGION:?ERROR: KONNECT_REGION not set in .env}"

# Match variable name used by 03-setup-cloud-gateway.sh
CP_NAME="${KONNECT_CONTROL_PLANE_NAME:-ollama-ai-gateway}"

CONFIG_FILE="$ROOT_DIR/deck/kong-config.yaml"
CONSUMERS_FILE="$ROOT_DIR/deck/kong-consumers.yaml"

DECK_FLAGS=(
  --konnect-addr "https://${KONNECT_REGION}.api.konghq.com"
  --konnect-token "$KONNECT_TOKEN"
  --konnect-control-plane-name "$CP_NAME"
)

if $CONFIG_ONLY; then
  STATE_FILES=("$CONFIG_FILE")
  echo "Mode: config only (services, routes, plugins)"
else
  if [[ ! -f "$CONSUMERS_FILE" ]]; then
    echo "WARNING: deck/kong-consumers.yaml not found."
    echo "         To include consumers, copy the template first:"
    echo "           cp deck/kong-consumers.yaml.sample deck/kong-consumers.yaml"
    echo "         Proceeding with config only..."
    STATE_FILES=("$CONFIG_FILE")
  else
    STATE_FILES=("$CONFIG_FILE" "$CONSUMERS_FILE")
    echo "Mode: config + consumers"
  fi
fi

echo ""
echo "==> Validating..."
deck gateway validate "${STATE_FILES[@]}" "${DECK_FLAGS[@]}"

echo ""
echo "==> Diff (changes to be applied)..."
deck gateway diff "${STATE_FILES[@]}" "${DECK_FLAGS[@]}"

echo ""
read -r -p "Apply these changes to Konnect? [y/N] " confirm
if [[ "${confirm,,}" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "==> Syncing to Konnect..."
deck gateway sync "${STATE_FILES[@]}" "${DECK_FLAGS[@]}"

echo ""
echo "Done. Kong config synced to Konnect."
