#!/bin/bash
# ============================================================
# Claude Code Mode Switcher
# Swap Claude Code between Anthropic API and private Ollama on EKS
#
# Ollama v0.14.0+ supports the Anthropic Messages API natively.
# Claude Code connects to Ollama using ANTHROPIC_BASE_URL (no /v1 suffix)
# and ANTHROPIC_AUTH_TOKEN for authentication.
#
# Modes:
#   remote     — Anthropic Claude API (default, billed to your account)
#   local      — Ollama on EKS via port-forward (recommended, no timeout)
#   cloudfront — Ollama via CloudFront + API key (no kubectl needed, 60s timeout)
#
# Requires: Ollama v0.14.0+ (Anthropic Messages API support)
# Current:  Ollama v0.18.2 on EKS
# ============================================================

_clean_env() {
  # Clean up ALL provider env vars to prevent conflicts
  unset ANTHROPIC_BASE_URL
  unset ANTHROPIC_AUTH_TOKEN
  unset OPENAI_BASE_URL
  unset OPENAI_API_KEY
  unset CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
}

usage() {
  echo "Usage: source claude-switch.sh [remote|local|cloudfront|status]"
  echo ""
  echo "  remote     - Use Anthropic's Claude API (default)"
  echo "  local      - Use private Ollama on EKS via port-forward (recommended)"
  echo "  cloudfront - Use Ollama via CloudFront + API key (no kubectl needed)"
  echo "  status     - Show current mode"
  echo ""
  echo "Options for 'cloudfront' mode:"
  echo "  --endpoint <URL>   CloudFront domain (e.g. https://xxx.cloudfront.net)"
  echo "  --apikey <KEY>     API Gateway API key"
  echo ""
  echo "Examples:"
  echo "  source claude-switch.sh local"
  echo "  source claude-switch.sh cloudfront --endpoint https://xxx.cloudfront.net --apikey mykey"
  echo "  source claude-switch.sh remote"
  echo ""
  echo "IMPORTANT: Must run with 'source' so env vars persist in your shell."
}

status() {
  if [[ "${ANTHROPIC_BASE_URL:-}" == *"cloudfront.net"* ]]; then
    echo "Mode:     CLOUDFRONT (Ollama via CloudFront VPC Origin)"
    echo "Endpoint: $ANTHROPIC_BASE_URL"
    echo "API Key:  ${ANTHROPIC_API_KEY:0:8}..."
    # Health check — CloudFront routes /v1/models to Ollama
    if curl -s --connect-timeout 5 "${ANTHROPIC_BASE_URL}/v1/models" \
         -H "x-api-key: ${ANTHROPIC_API_KEY}" 2>/dev/null | \
         python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Models:  {\", \".join(m[\"id\"] for m in d.get(\"data\",[]))}')" 2>/dev/null; then
      echo "Status:   CONNECTED"
    else
      echo "Status:   NOT REACHABLE"
    fi
    echo ""
    echo "Run:   claude --model qwen3.5:27b"
  elif [[ "${ANTHROPIC_BASE_URL:-}" == "http://localhost:11434" ]]; then
    echo "Mode:   LOCAL (Ollama on EKS via port-forward)"
    echo "URL:    $ANTHROPIC_BASE_URL"
    if curl -s --connect-timeout 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
      echo "Tunnel: CONNECTED"
      local models
      models=$(curl -s --connect-timeout 2 http://localhost:11434/api/tags 2>/dev/null | \
        python3 -c "import sys,json; [print(f'  - {m[\"name\"]}') for m in json.load(sys.stdin).get('models',[])]" 2>/dev/null)
      if [[ -n "$models" ]]; then
        echo "Models:"
        echo "$models"
      fi
    else
      echo "Tunnel: NOT CONNECTED"
      echo "  Run: kubectl port-forward -n ollama svc/ollama 11434:11434"
    fi
    echo ""
    echo "Run:   claude --model qwen3.5:27b"
  else
    echo "Mode:  REMOTE (Anthropic Claude API)"
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
      echo "Key:   set"
    else
      echo "Key:   NOT SET — run: export ANTHROPIC_API_KEY=\"sk-ant-...\""
    fi
    echo ""
    echo "Run:   claude"
  fi
}

set_remote() {
  if pgrep -f "kubectl port-forward -n ollama" > /dev/null 2>&1; then
    pkill -f "kubectl port-forward -n ollama"
    echo "Tunnel: stopped"
  fi

  _clean_env

  echo "Switched to REMOTE (Anthropic Claude API)"
  echo "Run:   claude"
}

set_local() {
  # Start port-forward if not already running
  if curl -s --connect-timeout 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "Tunnel: already connected"
  else
    echo "Starting port-forward tunnel..."
    kubectl port-forward -n ollama svc/ollama 11434:11434 > /dev/null 2>&1 &
    local pf_pid=$!

    for i in 1 2 3 4 5 6 7 8; do
      if curl -s --connect-timeout 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "Tunnel: CONNECTED (pid $pf_pid)"
        break
      fi
      sleep 2
    done

    if ! curl -s --connect-timeout 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
      echo "WARNING: Tunnel started but Ollama not responding"
      echo "  Check: kubectl get pods -n ollama"
    fi
  fi

  _clean_env

  # Ollama Anthropic Messages API — no /v1 suffix needed
  # Claude Code sends requests to $ANTHROPIC_BASE_URL/v1/messages
  export ANTHROPIC_BASE_URL="http://localhost:11434"
  export ANTHROPIC_AUTH_TOKEN="ollama"
  export ANTHROPIC_API_KEY=""
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

  echo ""
  echo "Switched to LOCAL (Ollama on EKS via port-forward)"
  echo "  URL:    http://localhost:11434"
  echo "  Auth:   ANTHROPIC_AUTH_TOKEN=ollama"
  echo ""
  echo "Run:   claude --model qwen3.5:27b"
}

set_cloudfront() {
  local endpoint=""
  local apikey=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --endpoint) endpoint="$2"; shift 2 ;;
      --apikey)   apikey="$2"; shift 2 ;;
      *)          shift ;;
    esac
  done

  if [[ -z "$endpoint" || -z "$apikey" ]]; then
    echo "ERROR: both --endpoint and --apikey are required"
    echo "Usage: source claude-switch.sh cloudfront --endpoint https://<CF_DOMAIN> --apikey <KEY>"
    return 1
  fi

  endpoint="${endpoint%/}"

  if pgrep -f "kubectl port-forward -n ollama" > /dev/null 2>&1; then
    pkill -f "kubectl port-forward -n ollama"
    echo "Tunnel: stopped"
  fi

  _clean_env

  # CloudFront routes /v1/messages directly to NLB VPC Origin (bypasses API Gateway).
  # CloudFront Function validates x-api-key header (same key as API Gateway).
  # No /v1 suffix — Claude Code appends /v1/messages automatically.
  export ANTHROPIC_BASE_URL="${endpoint}"
  export ANTHROPIC_AUTH_TOKEN="${apikey}"
  export ANTHROPIC_API_KEY="${apikey}"
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

  echo ""
  echo "Switched to CLOUDFRONT (Ollama via CloudFront VPC Origin)"
  echo "  Endpoint: ${endpoint}"
  echo "  API Key:  ${apikey:0:8}..."

  # Verify connectivity via /v1/models (OpenAI-compat endpoint, always available)
  local model_check
  model_check=$(curl -s --connect-timeout 5 "${endpoint}/v1/models" \
    -H "x-api-key: ${apikey}" 2>/dev/null)
  if echo "$model_check" | python3 -c "import sys,json; json.load(sys.stdin)" > /dev/null 2>&1; then
    echo "  Status:   CONNECTED"
    echo "$model_check" | python3 -c "
import sys,json
d=json.load(sys.stdin)
models=[m['id'] for m in d.get('data',[])]
if models: print(f'  Models:   {\", \".join(models)}')
" 2>/dev/null
  else
    echo "  Status:   NOT REACHABLE"
    echo "  Check:    Is Ollama running? (kubectl get pods -n ollama)"
  fi

  echo ""
  echo "NOTE: CloudFront has a 60s origin timeout. For long responses, use 'local' mode."
  echo "Run:   claude --model qwen3.5:27b"
}

case "${1:-}" in
  remote)     set_remote ;;
  local)      set_local ;;
  cloudfront) shift; set_cloudfront "$@" ;;
  status)     status ;;
  *)          usage ;;
esac
