#!/bin/bash
# ============================================================
# Claude Mode Switcher
# Swap between Anthropic API, private EKS Ollama (port-forward),
# and Kong Cloud AI Gateway
# ============================================================

usage() {
  echo "Usage: source claude-switch.sh [remote|local|ollama|status]"
  echo ""
  echo "  remote   - Use Anthropic's Claude API (default)"
  echo "  local    - Use private Ollama on EKS (requires port-forward)"
  echo "  ollama   - Use Ollama via Kong Cloud AI Gateway (no kubectl needed)"
  echo "  status   - Show current mode"
  echo ""
  echo "Options for 'ollama' mode:"
  echo "  --endpoint <URL>   Kong proxy URL (from Konnect UI)"
  echo "  --apikey <KEY>     API key for Kong authentication"
  echo ""
  echo "Examples:"
  echo "  source claude-switch.sh remote"
  echo "  source claude-switch.sh local"
  echo "  source claude-switch.sh ollama --endpoint https://xxx.kong-cloud.com --apikey mykey"
  echo ""
  echo "IMPORTANT: Run with 'source' so env vars persist in your shell."
}

status() {
  if [[ -n "${KONG_PROXY_URL:-}" ]]; then
    echo "Mode:     OLLAMA via Kong Cloud AI Gateway"
    echo "Endpoint: $ANTHROPIC_BASE_URL"
    echo "API Key:  ${ANTHROPIC_API_KEY:0:8}..."
    echo ""
    if curl -s --connect-timeout 5 "${KONG_PROXY_URL}/api/tags" -H "apikey: ${ANTHROPIC_API_KEY}" > /dev/null 2>&1; then
      echo "Status: CONNECTED"
    else
      echo "Status: NOT REACHABLE — check Kong proxy URL and API key"
    fi
    echo ""
    echo "Run:   claude --model qwen3-coder:30b"
  elif [ "$ANTHROPIC_BASE_URL" = "http://localhost:11434" ]; then
    echo "Mode:   LOCAL (Ollama on EKS via port-forward)"
    echo "URL:    $ANTHROPIC_BASE_URL"
    if curl -s --connect-timeout 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
      echo "Tunnel: CONNECTED"
    else
      echo "Tunnel: NOT CONNECTED — run: kubectl port-forward -n ollama svc/ollama 11434:11434"
    fi
    echo ""
    echo "Run:   claude --model qwen3-coder:30b"
  else
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      echo "Mode:  REMOTE (Anthropic API)"
      echo "Key:   set (env var)"
    elif grep -qs "ANTHROPIC_API_KEY" ~/.zshrc 2>/dev/null; then
      echo "Mode:  REMOTE (Anthropic API)"
      echo "Key:   set (in ~/.zshrc — open a new terminal or run: source ~/.zshrc)"
    else
      echo "Mode:  REMOTE (Anthropic API)"
      echo "Key:   NOT SET — run: export ANTHROPIC_API_KEY=\"sk-ant-...\""
    fi
    echo ""
    echo "Run:   claude"
  fi
}

set_remote() {
  # Kill any port-forward tunnel we started
  if pgrep -f "kubectl port-forward -n ollama" > /dev/null 2>&1; then
    pkill -f "kubectl port-forward -n ollama"
    echo "Tunnel: stopped"
  fi

  unset ANTHROPIC_BASE_URL
  unset ANTHROPIC_AUTH_TOKEN
  unset CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
  unset KONG_PROXY_URL

  echo "Switched to REMOTE (Anthropic API)"
  echo ""
  echo "Run:   claude"
}

set_local() {
  # Clear Kong vars if set
  unset KONG_PROXY_URL

  # Start port-forward in background if not already running
  if curl -s --connect-timeout 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "Tunnel: already connected"
  else
    echo "Starting port-forward tunnel..."
    kubectl port-forward -n ollama svc/ollama 11434:11434 > /dev/null 2>&1 &
    CLAUDE_PF_PID=$!

    # Wait for tunnel to be ready
    for i in 1 2 3 4 5; do
      if curl -s --connect-timeout 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "Tunnel: CONNECTED (pid $CLAUDE_PF_PID)"
        break
      fi
      sleep 1
    done

    if ! curl -s --connect-timeout 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
      echo "WARNING: Tunnel started but Ollama not responding yet"
      echo "  Check pod status: kubectl get pods -n ollama"
      echo "  Tunnel pid: $CLAUDE_PF_PID"
    fi
  fi

  export ANTHROPIC_BASE_URL="http://localhost:11434"
  export ANTHROPIC_AUTH_TOKEN="ollama"
  export ANTHROPIC_API_KEY=""
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

  echo ""
  echo "Switched to LOCAL (Ollama on EKS via port-forward)"
  echo ""
  echo "Run:   claude --model qwen3-coder:30b"
}

set_ollama() {
  local endpoint=""
  local apikey=""

  # Parse --endpoint and --apikey flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --endpoint)
        endpoint="$2"
        shift 2
        ;;
      --apikey)
        apikey="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ -z "$endpoint" ]]; then
    echo "ERROR: --endpoint is required"
    echo ""
    echo "Usage: source claude-switch.sh ollama --endpoint https://<KONG_PROXY_URL> --apikey <KEY>"
    echo ""
    echo "Get your Kong proxy URL from Konnect UI:"
    echo "  https://cloud.konghq.com → Gateway Manager → Data Plane Nodes"
    return 1
  fi

  # Strip trailing slash
  endpoint="${endpoint%/}"

  if [[ -z "$apikey" ]]; then
    echo "WARNING: No --apikey provided. Requests will fail if key-auth is enabled."
    echo "  Add: --apikey <your-key>"
    apikey="no-key"
  fi

  # Kill any port-forward tunnel
  if pgrep -f "kubectl port-forward -n ollama" > /dev/null 2>&1; then
    pkill -f "kubectl port-forward -n ollama"
    echo "Tunnel: stopped (no longer needed with Kong)"
  fi

  export KONG_PROXY_URL="$endpoint"
  export ANTHROPIC_BASE_URL="$endpoint"
  export ANTHROPIC_API_KEY="$apikey"   # Sent as x-api-key header → matches Kong key-auth
  unset ANTHROPIC_AUTH_TOKEN
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

  echo ""
  echo "Switched to OLLAMA via Kong Cloud AI Gateway"
  echo ""
  echo "  Endpoint: $endpoint"
  echo "  API Key:  ${apikey:0:8}..."
  echo ""

  # Quick connectivity check
  if curl -s --connect-timeout 5 "${endpoint}/api/tags" -H "apikey: ${apikey}" > /dev/null 2>&1; then
    echo "  Status: CONNECTED"
  else
    echo "  Status: Could not reach endpoint (may still be provisioning)"
  fi

  echo ""
  echo "Run:   claude --model qwen3-coder:30b"
}

case "${1:-}" in
  remote) set_remote ;;
  local)  set_local ;;
  ollama) shift; set_ollama "$@" ;;
  status) status ;;
  *)      usage ;;
esac
