#!/bin/bash
# ============================================================
# Claude Mode Switcher
# Swap between Anthropic remote API and private EKS Ollama
# ============================================================

usage() {
  echo "Usage: source claude-switch.sh [remote|local|status]"
  echo ""
  echo "  remote   - Use Anthropic's Claude API (default)"
  echo "  local    - Use private Ollama on EKS (requires port-forward)"
  echo "  status   - Show current mode"
  echo ""
  echo "IMPORTANT: Run with 'source' so env vars persist in your shell:"
  echo "  source claude-switch.sh local"
  echo "  source claude-switch.sh remote"
}

status() {
  if [ "$ANTHROPIC_BASE_URL" = "http://localhost:11434" ]; then
    echo "Mode:  LOCAL (Ollama on EKS)"
    echo "URL:   $ANTHROPIC_BASE_URL"
    # Check if tunnel is active
    if curl -s --connect-timeout 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
      echo "Tunnel: CONNECTED"
    else
      echo "Tunnel: NOT CONNECTED — run: kubectl port-forward -n ollama svc/ollama 11434:11434"
    fi
    echo ""
    echo "Run:   claude --model qwen3-coder:32b"
  else
    # Check env var, then grep from shell profile
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

  echo "Switched to REMOTE (Anthropic API)"
  echo ""
  echo "Run:   claude"
}

set_local() {
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
  echo "Switched to LOCAL (Ollama on EKS)"
  echo ""
  echo "Run:   claude --model qwen3-coder:32b"
}

case "${1:-}" in
  remote) set_remote ;;
  local)  set_local ;;
  status) status ;;
  *)      usage ;;
esac
