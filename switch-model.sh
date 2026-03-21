#!/bin/bash
# ============================================================
# Ollama Model Switcher for EKS
# Switch between Qwen 3.5 model tiers on your GPU cluster
# ============================================================

set -euo pipefail

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

NAMESPACE="${OLLAMA_NAMESPACE:-ollama}"
OLLAMA_POD=""
OLLAMA_URL="http://localhost:11434"

# ============================================================
# Model Tiers — edit these to add/change models
# ============================================================
# Format: "model_tag|display_name|vram_needed|gpu_instance|description"
MODELS=(
  "qwen3.5:27b|Qwen 3.5 27B (Dense)|~18GB|g5.xlarge (1x A10G)|Fallback tier. Fast, dense model. Ties GPT-5 mini on SWE-bench (72.4%). Best for quick iteration."
  "qwen3-coder:30b-a3b|Qwen3-Coder 30B-A3B (MoE)|~20GB|g5.xlarge (1x A10G)|Coding-specialised MoE. Only 3.3B active params = very fast inference."
  "qwen3.5:122b-a10b|Qwen 3.5 122B-A10B (MoE)|~72GB Q4|g5.12xlarge (4x A10G)|DEFAULT. Flagship quality. Beats GPT-5 mini on tool use (+30%)."
)

# ============================================================
# Helpers
# ============================================================
print_header() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC}  ${BOLD}Ollama Model Switcher${NC} — Qwen 3.5 on EKS            ${BLUE}║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
}

get_pod() {
  OLLAMA_POD=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$OLLAMA_POD" ]]; then
    echo -e "${RED}Error: No Ollama pod found in namespace '$NAMESPACE'${NC}"
    echo -e "Is the cluster running? Try: ${CYAN}kubectl get pods -n $NAMESPACE${NC}"
    exit 1
  fi
}

check_port_forward() {
  if ! curl -s "$OLLAMA_URL/api/tags" &>/dev/null; then
    echo -e "${YELLOW}Port-forward not active. Starting...${NC}"
    kubectl port-forward -n "$NAMESPACE" svc/ollama 11434:11434 &>/dev/null &
    sleep 2
    if ! curl -s "$OLLAMA_URL/api/tags" &>/dev/null; then
      echo -e "${RED}Could not reach Ollama at $OLLAMA_URL${NC}"
      echo -e "Start port-forward manually: ${CYAN}kubectl port-forward -n $NAMESPACE svc/ollama 11434:11434${NC}"
      exit 1
    fi
    echo -e "${GREEN}Port-forward started${NC}"
  fi
}

get_current_model() {
  # Get list of loaded models
  local loaded
  loaded=$(curl -s "$OLLAMA_URL/api/ps" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('models', [])
    for m in models:
        print(m.get('name', 'unknown'))
except:
    pass
" 2>/dev/null)
  echo "$loaded"
}

get_available_models() {
  curl -s "$OLLAMA_URL/api/tags" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('models', [])
    for m in models:
        name = m.get('name', '')
        size_gb = m.get('size', 0) / (1024**3)
        print(f'{name}|{size_gb:.1f}GB')
except:
    pass
" 2>/dev/null
}

# ============================================================
# Commands
# ============================================================
cmd_status() {
  print_header
  check_port_forward

  echo -e "${BOLD}Current Status${NC}"
  echo -e "─────────────────────────────────────────"

  # Pod info
  echo -e "  Pod:       ${CYAN}$OLLAMA_POD${NC}"
  local node
  node=$(kubectl get pod "$OLLAMA_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")
  local instance_type
  instance_type=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")
  echo -e "  Node:      ${CYAN}$node${NC}"
  echo -e "  Instance:  ${CYAN}$instance_type${NC}"

  # Loaded model
  local current
  current=$(get_current_model)
  if [[ -n "$current" ]]; then
    echo -e "  Loaded:    ${GREEN}$current${NC}"
  else
    echo -e "  Loaded:    ${YELLOW}(none currently loaded)${NC}"
  fi

  # Available models
  echo ""
  echo -e "${BOLD}Downloaded Models${NC}"
  echo -e "─────────────────────────────────────────"
  local available
  available=$(get_available_models)
  if [[ -n "$available" ]]; then
    while IFS='|' read -r name size; do
      echo -e "  ${GREEN}●${NC} $name  ${CYAN}($size)${NC}"
    done <<< "$available"
  else
    echo -e "  ${YELLOW}(no models downloaded yet)${NC}"
  fi
  echo ""
}

cmd_list() {
  print_header
  echo -e "${BOLD}Available Model Tiers${NC}"
  echo ""

  local i=1
  for model_info in "${MODELS[@]}"; do
    IFS='|' read -r tag name vram gpu desc <<< "$model_info"

    local color="$NC"
    case $i in
      1) color="$GREEN" ;;
      2) color="$CYAN" ;;
      3) color="$PURPLE" ;;
    esac

    echo -e "  ${color}${BOLD}[$i] $name${NC}"
    echo -e "      Tag:      ${CYAN}$tag${NC}"
    echo -e "      VRAM:     $vram"
    echo -e "      GPU:      $gpu"
    echo -e "      ${desc}"
    echo ""
    ((i++))
  done

  echo -e "  ${BOLD}Usage:${NC}"
  echo -e "    ${CYAN}./switch-model.sh use 3${NC}     → Switch to tier 3 (flagship — DEFAULT)"
  echo -e "    ${CYAN}./switch-model.sh use 1${NC}     → Switch to tier 1 (fast, cheap fallback)"
  echo -e "    ${CYAN}./switch-model.sh use qwen3.5:27b${NC} → Switch by model tag"
  echo ""
}

cmd_use() {
  local target="$1"
  local model_tag=""
  local model_name=""

  # Check if target is a number (tier selection)
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    local idx=$((target - 1))
    if [[ $idx -lt 0 || $idx -ge ${#MODELS[@]} ]]; then
      echo -e "${RED}Invalid tier number. Use 1-${#MODELS[@]}${NC}"
      exit 1
    fi
    IFS='|' read -r model_tag model_name _ _ _ <<< "${MODELS[$idx]}"
  else
    # Treat as a model tag directly
    model_tag="$target"
    model_name="$target"
  fi

  print_header
  check_port_forward

  echo -e "${BOLD}Switching to: ${CYAN}$model_name${NC} (${CYAN}$model_tag${NC})"
  echo ""

  # Check if model is already downloaded
  local available
  available=$(get_available_models)
  if echo "$available" | grep -q "^${model_tag}|"; then
    echo -e "  ${GREEN}✓${NC} Model already downloaded"
  else
    echo -e "  ${YELLOW}↓${NC} Pulling model (this may take a while for large models)..."
    echo -e "    ${CYAN}ollama pull $model_tag${NC}"
    curl -s "$OLLAMA_URL/api/pull" -d "{\"name\": \"$model_tag\"}" | while read -r line; do
      local status
      status=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
      if [[ -n "$status" ]]; then
        echo -ne "\r    $status                              "
      fi
    done
    echo ""
    echo -e "  ${GREEN}✓${NC} Model downloaded"
  fi

  # Unload current model if any
  local current
  current=$(get_current_model)
  if [[ -n "$current" && "$current" != "$model_tag" ]]; then
    echo -e "  ${YELLOW}⏏${NC} Unloading current model ($current)..."
    curl -s "$OLLAMA_URL/api/generate" -d "{\"model\": \"$current\", \"keep_alive\": 0}" >/dev/null 2>&1
    sleep 1
    echo -e "  ${GREEN}✓${NC} Unloaded"
  fi

  # Load the new model with a quick warmup
  echo -e "  ${YELLOW}⟳${NC} Loading $model_tag into GPU memory..."
  curl -s "$OLLAMA_URL/api/generate" -d "{\"model\": \"$model_tag\", \"prompt\": \"hi\", \"options\": {\"num_predict\": 1}}" >/dev/null 2>&1
  echo -e "  ${GREEN}✓${NC} Model loaded and ready"

  echo ""
  echo -e "${GREEN}${BOLD}Done!${NC} Now use Claude Code with:"
  echo -e "  ${CYAN}claude --model $model_tag${NC}"
  echo ""
}

cmd_pull_all() {
  print_header
  check_port_forward

  echo -e "${BOLD}Downloading all model tiers...${NC}"
  echo ""
  for model_info in "${MODELS[@]}"; do
    IFS='|' read -r tag name _ _ _ <<< "$model_info"
    echo -e "  ${YELLOW}↓${NC} Pulling ${CYAN}$name${NC} ($tag)..."
    curl -s "$OLLAMA_URL/api/pull" -d "{\"name\": \"$tag\"}" | while read -r line; do
      local status
      status=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
      if [[ -n "$status" ]]; then
        echo -ne "\r    $status                              "
      fi
    done
    echo ""
    echo -e "  ${GREEN}✓${NC} $tag ready"
    echo ""
  done
  echo -e "${GREEN}${BOLD}All models downloaded!${NC}"
}

# ============================================================
# Main
# ============================================================
cmd="${1:-help}"

case "$cmd" in
  status|s)
    get_pod
    cmd_status
    ;;
  list|ls|l)
    cmd_list
    ;;
  use|switch|u)
    if [[ -z "${2:-}" ]]; then
      echo -e "${RED}Usage: $0 use <tier_number|model_tag>${NC}"
      echo -e "Run '$0 list' to see available tiers"
      exit 1
    fi
    get_pod
    cmd_use "$2"
    ;;
  pull-all|download)
    get_pod
    cmd_pull_all
    ;;
  help|--help|-h|*)
    print_header
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${CYAN}list${NC}              Show available model tiers with details"
    echo -e "  ${CYAN}status${NC}            Show current pod, node, and loaded model"
    echo -e "  ${CYAN}use <tier|tag>${NC}    Switch to a model (by tier number or Ollama tag)"
    echo -e "  ${CYAN}pull-all${NC}          Download all model tiers (pre-cache)"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  ${CYAN}$0 list${NC}"
    echo -e "  ${CYAN}$0 use 1${NC}              → Fast tier (qwen3.5:27b on g5.xlarge)"
    echo -e "  ${CYAN}$0 use 3${NC}              → Flagship (qwen3.5:122b on g5.12xlarge)"
    echo -e "  ${CYAN}$0 use qwen3-coder:30b-a3b${NC} → By exact tag"
    echo -e "  ${CYAN}$0 status${NC}"
    echo ""
    ;;
esac
