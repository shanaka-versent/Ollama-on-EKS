#!/bin/bash
# ============================================================
# Ollama Model Switcher for EKS — Flex Mode
# Switch between Qwen 3.5 model tiers on your GPU cluster.
#
# How it works:
#   1. Patches Ollama deployment resources (GPU, memory, CPU)
#   2. Karpenter auto-provisions the right instance type
#   3. KEDA is paused during the switch to prevent scale-to-zero
#   4. Model is loaded and warmed up
#
# Tier 1 & 2: g5.xlarge  (1x A10G, 24GB) — $0.35/hr spot
# Tier 3:     g5.12xlarge (4x A10G, 96GB) — $1.90/hr spot
# Idle:       No GPU node at all          — $0/hr (KEDA + Karpenter)
#
# The NodePool ceiling allows both instance types. Karpenter
# provisions based on pod resource requests — not the ceiling.
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
KEDA_NAMESPACE="ollama"
KEDA_SCALEDOBJECT="ollama-autoscaler"

# Safety trap: if script is interrupted (Ctrl+C, terminal close, kill),
# unpause KEDA so it can scale to zero. Without this, KEDA stays paused
# and the GPU node runs at $0.35-$1.90/hr until someone notices.
KEDA_WAS_PAUSED_BY_US=false
cleanup_on_interrupt() {
  echo ""
  echo -e "  ${RED}Interrupted!${NC} Ensuring KEDA is unpaused..."
  if $KEDA_WAS_PAUSED_BY_US; then
    kubectl annotate scaledobject "$KEDA_SCALEDOBJECT" -n "$KEDA_NAMESPACE" \
      autoscaling.keda.sh/paused- \
      --overwrite 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} KEDA unpaused — will scale to zero after idle timeout"
  fi
  # Kill any port-forward we started
  pkill -f "kubectl port-forward.*ollama.*11434" 2>/dev/null || true
  exit 1
}
trap cleanup_on_interrupt INT TERM

# ============================================================
# Model Tiers — Hardware & Resource Requirements
# ============================================================
# Format: "tag|name|vram|min_gpus|instance|gpu_limit|mem_limit|mem_req|cpu_limit|cpu_req|description"
MODELS=(
  "qwen3.5:27b|Qwen 3.5 27B (Dense)|~18GB|1|g5.xlarge|1|14Gi|12Gi|3|2|Fallback. Fast dense model for testing and quick iteration."
  "qwen3-coder:30b-a3b|Qwen3-Coder 30B-A3B (MoE)|~20GB|1|g5.xlarge|1|14Gi|12Gi|3|2|Coding-specialised MoE. Only 3.3B active params = very fast."
  "qwen3.5:122b-a10b|Qwen 3.5 122B-A10B (MoE)|~72GB Q4|4|g5.12xlarge|4|96Gi|64Gi|16|8|Flagship. Best quality. Karpenter auto-provisions g5.12xlarge."
)

# ============================================================
# Helpers
# ============================================================
print_header() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC}  ${BOLD}Ollama Model Switcher${NC} — Flex Mode (Qwen 3.5 on EKS)       ${BLUE}║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

get_pod() {
  OLLAMA_POD=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$OLLAMA_POD" ]]; then
    echo -e "${RED}Error: No Ollama pod found in namespace '$NAMESPACE'${NC}"
    echo -e "Is the cluster running? Try: ${CYAN}kubectl get pods -n $NAMESPACE${NC}"
    echo -e "If KEDA scaled to zero, run: ${CYAN}./scripts/scale-up.sh${NC}"
    exit 1
  fi
}

check_port_forward() {
  if ! curl -s --max-time 3 "$OLLAMA_URL/api/tags" &>/dev/null; then
    echo -e "${YELLOW}Port-forward not active. Starting...${NC}"
    kubectl port-forward -n "$NAMESPACE" svc/ollama 11434:11434 &>/dev/null &
    sleep 3
    if ! curl -s --max-time 3 "$OLLAMA_URL/api/tags" &>/dev/null; then
      echo -e "${RED}Could not reach Ollama at $OLLAMA_URL${NC}"
      echo -e "Start port-forward manually: ${CYAN}kubectl port-forward -n $NAMESPACE svc/ollama 11434:11434${NC}"
      exit 1
    fi
    echo -e "${GREEN}Port-forward started${NC}"
  fi
}

get_node_info() {
  local node
  node=$(kubectl get pod "$OLLAMA_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
  if [[ -z "$node" ]]; then
    echo "unknown|0"
    return
  fi
  local instance_type
  instance_type=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")
  local gpu_count
  gpu_count=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")
  echo "${instance_type}|${gpu_count}"
}

get_current_model() {
  local loaded
  loaded=$(curl -s --max-time 5 "$OLLAMA_URL/api/ps" 2>/dev/null | python3 -c "
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
  curl -s --max-time 5 "$OLLAMA_URL/api/tags" 2>/dev/null | python3 -c "
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

get_current_resources() {
  local gpu
  gpu=$(kubectl get deployment ollama -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.nvidia\.com/gpu}' 2>/dev/null || echo "?")
  local mem
  mem=$(kubectl get deployment ollama -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "?")
  local cpu
  cpu=$(kubectl get deployment ollama -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "?")
  echo "${gpu}|${mem}|${cpu}"
}

# ============================================================
# NodePool Validation
# ============================================================
# Checks if the GPU NodePool allows enough GPUs for the requested tier.
# The NodePool ceiling must be >= the tier's GPU requirement.
check_nodepool() {
  local min_gpus="$1"
  local required_instance="$2"

  local nodepool_gpu_limit
  nodepool_gpu_limit=$(kubectl get nodepool gpu-ollama -o jsonpath='{.spec.limits.nvidia\.com/gpu}' 2>/dev/null || echo "0")

  if [[ "$nodepool_gpu_limit" -lt "$min_gpus" ]]; then
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  NODEPOOL LIMIT TOO LOW — Cannot provision ${required_instance}     ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Requires:${NC}  NodePool GPU limit ≥ ${min_gpus} (current: ${nodepool_gpu_limit})"
    echo -e "  ${BOLD}Instance:${NC}  ${CYAN}${required_instance}${NC} (${min_gpus}x A10G)"
    echo ""
    echo -e "${BOLD}  To fix, apply the flex NodePool patch:${NC}"
    echo ""
    echo -e "  ${YELLOW}1.${NC} Check ${CYAN}k8s/nodepools/gpu-nodepool.yaml${NC} includes 12xlarge"
    echo -e "     and limits are set to 48 CPU / 192Gi / 4 GPU"
    echo ""
    echo -e "  ${YELLOW}2.${NC} Commit and push — ArgoCD syncs the NodePool change"
    echo ""
    echo -e "  ${YELLOW}3.${NC} Re-run: ${CYAN}./switch-model.sh use 3${NC}"
    echo ""
    echo -e "  ${YELLOW}Prereq:${NC}  AWS GPU quota (L-3819A6DF) must be ≥ 48 vCPUs."
    echo -e "           Request via Service Quotas console (1-3 day approval)."
    echo ""
    return 1
  fi
  return 0
}

# ============================================================
# KEDA Pause / Unpause
# ============================================================
pause_keda() {
  echo -e "  ${YELLOW}⏸${NC}  Pausing KEDA auto-scaler..."
  kubectl annotate scaledobject "$KEDA_SCALEDOBJECT" -n "$KEDA_NAMESPACE" \
    autoscaling.keda.sh/paused="true" --overwrite 2>/dev/null || true
  KEDA_WAS_PAUSED_BY_US=true
  echo -e "  ${GREEN}✓${NC} KEDA paused (won't scale to zero during switch)"
}

unpause_keda() {
  echo -e "  ${GREEN}▶${NC}  Resuming KEDA auto-scaler..."
  kubectl annotate scaledobject "$KEDA_SCALEDOBJECT" -n "$KEDA_NAMESPACE" \
    autoscaling.keda.sh/paused- --overwrite 2>/dev/null || true
  echo -e "  ${GREEN}✓${NC} KEDA resumed (will scale to zero after 15 min idle)"
}

# ============================================================
# Deployment Patching
# ============================================================
patch_deployment() {
  local gpu_limit="$1"
  local mem_limit="$2"
  local mem_req="$3"
  local cpu_limit="$4"
  local cpu_req="$5"

  echo -e "  ${YELLOW}⟳${NC}  Patching Ollama deployment: ${CYAN}${gpu_limit} GPU, ${mem_limit} mem, ${cpu_limit} CPU${NC}"

  kubectl patch deployment ollama -n "$NAMESPACE" --type='json' -p="[
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/nvidia.com~1gpu\", \"value\": \"${gpu_limit}\"},
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/memory\", \"value\": \"${mem_limit}\"},
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/cpu\", \"value\": \"${cpu_limit}\"},
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/nvidia.com~1gpu\", \"value\": \"${gpu_limit}\"},
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/memory\", \"value\": \"${mem_req}\"},
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/cpu\", \"value\": \"${cpu_req}\"}
  ]" 2>&1

  echo -e "  ${GREEN}✓${NC} Deployment patched"
}

sync_webui_models() {
  local gpu_count="$1"
  local active_model="$2"
  local webui_ns="open-webui"
  local webui_deploy="open-webui"

  # Build model list based on what hardware can support
  local filter_list=""
  if [[ "$gpu_count" -ge 4 ]]; then
    # Flagship hardware — all models can run
    filter_list="qwen3.5:27b;qwen3-coder:30b-a3b;qwen3.5:122b-a10b"
  else
    # Standard hardware — only Tier 1 + Tier 2
    filter_list="qwen3.5:27b;qwen3-coder:30b-a3b"
  fi

  echo -e "  ${YELLOW}⟳${NC}  Syncing WebUI model list: ${CYAN}${filter_list}${NC}"
  echo -e "  ${YELLOW}⟳${NC}  Default model: ${CYAN}${active_model}${NC}"

  # Find the env var indices in the container spec
  local patch
  patch=$(kubectl get deployment "$webui_deploy" -n "$webui_ns" -o json 2>/dev/null | python3 -c "
import sys, json
deploy = json.load(sys.stdin)
envs = deploy['spec']['template']['spec']['containers'][0]['env']
ops = []
for i, e in enumerate(envs):
    if e['name'] == 'MODEL_FILTER_LIST':
        ops.append({'op': 'replace', 'path': f'/spec/template/spec/containers/0/env/{i}/value', 'value': '${filter_list}'})
    elif e['name'] == 'DEFAULT_MODELS':
        ops.append({'op': 'replace', 'path': f'/spec/template/spec/containers/0/env/{i}/value', 'value': '${active_model}'})
print(json.dumps(ops))
" 2>/dev/null)

  if [[ -z "$patch" || "$patch" == "[]" ]]; then
    echo -e "  ${YELLOW}⚠${NC}  WebUI deployment not found or missing env vars — skipping"
    return 0
  fi

  kubectl patch deployment "$webui_deploy" -n "$webui_ns" --type='json' -p="$patch" 2>&1
  echo -e "  ${GREEN}✓${NC} WebUI model list updated"
}

wait_for_rollout() {
  echo -e "  ${YELLOW}⏳${NC} Waiting for rollout (Karpenter provisioning node ~2-3 min)..."
  if kubectl rollout status deployment/ollama -n "$NAMESPACE" --timeout=600s 2>&1; then
    echo -e "  ${GREEN}✓${NC} Rollout complete"
  else
    echo -e "${RED}  ✗ Rollout timed out. Check: kubectl get pods -n $NAMESPACE${NC}"
    unpause_keda
    exit 1
  fi
}

# ============================================================
# Commands
# ============================================================
cmd_status() {
  print_header

  # Deployment resources
  local res
  res=$(get_current_resources)
  local cur_gpu cur_mem cur_cpu
  cur_gpu=$(echo "$res" | cut -d'|' -f1)
  cur_mem=$(echo "$res" | cut -d'|' -f2)
  cur_cpu=$(echo "$res" | cut -d'|' -f3)

  echo -e "${BOLD}Deployment Resources${NC}"
  echo -e "─────────────────────────────────────────"
  echo -e "  GPU:       ${CYAN}${cur_gpu}${NC}"
  echo -e "  Memory:    ${CYAN}${cur_mem}${NC}"
  echo -e "  CPU:       ${CYAN}${cur_cpu}${NC}"

  # Detect current tier
  local tier_name="Unknown"
  for model_info in "${MODELS[@]}"; do
    IFS='|' read -r _ name _ _ _ gpu_l mem_l _ _ _ _ <<< "$model_info"
    if [[ "$cur_gpu" == "$gpu_l" && "$cur_mem" == "$mem_l" ]]; then
      tier_name="$name"
      break
    fi
  done
  echo -e "  Tier:      ${GREEN}${tier_name}${NC}"

  # Pod & node info
  echo ""
  echo -e "${BOLD}Node & Pod${NC}"
  echo -e "─────────────────────────────────────────"
  get_pod 2>/dev/null || true
  if [[ -n "$OLLAMA_POD" ]]; then
    echo -e "  Pod:       ${CYAN}$OLLAMA_POD${NC}"
    local node_info
    node_info=$(get_node_info)
    local instance_type gpu_count
    instance_type=$(echo "$node_info" | cut -d'|' -f1)
    gpu_count=$(echo "$node_info" | cut -d'|' -f2)
    local node
    node=$(kubectl get pod "$OLLAMA_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")
    echo -e "  Node:      ${CYAN}$node${NC}"
    echo -e "  Instance:  ${CYAN}$instance_type${NC} (${gpu_count}x GPU)"

    # Loaded model
    check_port_forward 2>/dev/null || true
    local current
    current=$(get_current_model)
    if [[ -n "$current" ]]; then
      echo -e "  Loaded:    ${GREEN}$current${NC}"
    else
      echo -e "  Loaded:    ${YELLOW}(none currently loaded)${NC}"
    fi

    # Downloaded models
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
  else
    echo -e "  ${YELLOW}No Ollama pod running (KEDA scaled to zero)${NC}"
    echo -e "  Run ${CYAN}./scripts/scale-up.sh${NC} to start"
  fi

  # NodePool limits
  echo ""
  echo -e "${BOLD}NodePool Ceiling (gpu-ollama)${NC}"
  echo -e "─────────────────────────────────────────"
  local np_gpu np_cpu np_mem
  np_gpu=$(kubectl get nodepool gpu-ollama -o jsonpath='{.spec.limits.nvidia\.com/gpu}' 2>/dev/null || echo "?")
  np_cpu=$(kubectl get nodepool gpu-ollama -o jsonpath='{.spec.limits.cpu}' 2>/dev/null || echo "?")
  np_mem=$(kubectl get nodepool gpu-ollama -o jsonpath='{.spec.limits.memory}' 2>/dev/null || echo "?")
  echo -e "  GPU limit: ${CYAN}${np_gpu}${NC}    CPU limit: ${CYAN}${np_cpu}${NC}    Memory limit: ${CYAN}${np_mem}${NC}"

  local flex_capable="No"
  if [[ "${np_gpu}" -ge 4 ]] 2>/dev/null; then
    flex_capable="Yes"
  fi
  echo -e "  Flex mode: ${GREEN}${flex_capable}${NC} (can switch to Tier 3 flagship)"

  # Available tiers
  echo ""
  echo -e "${BOLD}Available Tiers${NC}"
  echo -e "─────────────────────────────────────────"
  local i=1
  for model_info in "${MODELS[@]}"; do
    IFS='|' read -r tag name vram min_gpus req_instance _ _ _ _ _ desc <<< "$model_info"
    if [[ "${np_gpu:-0}" -ge "$min_gpus" ]] 2>/dev/null; then
      echo -e "  ${GREEN}✓${NC} [$i] $name  ${CYAN}($req_instance)${NC}"
    else
      echo -e "  ${RED}✗${NC} [$i] $name  ${RED}(needs NodePool GPU ≥ $min_gpus)${NC}"
    fi
    ((i++))
  done
  echo ""
}

cmd_list() {
  print_header
  echo -e "${BOLD}Available Model Tiers${NC}"
  echo ""

  local i=1
  for model_info in "${MODELS[@]}"; do
    IFS='|' read -r tag name vram min_gpus instance gpu_l mem_l mem_r cpu_l cpu_r desc <<< "$model_info"

    local color="$NC"
    case $i in
      1) color="$GREEN" ;;
      2) color="$CYAN" ;;
      3) color="$PURPLE" ;;
    esac

    echo -e "  ${color}${BOLD}[$i] $name${NC}"
    echo -e "      Tag:       ${CYAN}$tag${NC}"
    echo -e "      VRAM:      $vram"
    echo -e "      Instance:  $instance (${min_gpus}x A10G)"
    echo -e "      Resources: ${gpu_l} GPU, ${mem_l}/${mem_r} mem, ${cpu_l}/${cpu_r} CPU"
    echo -e "      ${desc}"
    echo ""
    ((i++))
  done

  echo -e "  ${BOLD}How Flex Mode Works:${NC}"
  echo -e "  ┌──────────────────────────────────────────────────────────────────┐"
  echo -e "  │ The NodePool ceiling allows BOTH g5.xlarge and g5.12xlarge.     │"
  echo -e "  │ Karpenter provisions based on what the Ollama pod REQUESTS:     │"
  echo -e "  │                                                                  │"
  echo -e "  │  Tier 1/2 (1 GPU)  → g5.xlarge   → \$0.35/hr spot              │"
  echo -e "  │  Tier 3   (4 GPUs) → g5.12xlarge  → \$1.90/hr spot              │"
  echo -e "  │  KEDA idle (0 pods) → no GPU node → \$0/hr                      │"
  echo -e "  │                                                                  │"
  echo -e "  │  switch-model.sh patches the deployment, Karpenter swaps nodes. │"
  echo -e "  └──────────────────────────────────────────────────────────────────┘"
  echo ""
  echo -e "  ${BOLD}Usage:${NC}"
  echo -e "    ${CYAN}./switch-model.sh use 1${NC}     → Tier 1 fallback  (g5.xlarge, ~3 min)"
  echo -e "    ${CYAN}./switch-model.sh use 2${NC}     → Tier 2 coder     (g5.xlarge, ~3 min)"
  echo -e "    ${CYAN}./switch-model.sh use 3${NC}     → Tier 3 flagship  (g5.12xlarge, ~5 min)"
  echo -e "    ${CYAN}./switch-model.sh status${NC}    → Show current tier, hardware, models"
  echo ""
}

cmd_use() {
  local target="$1"
  local model_tag="" model_name="" min_gpus="" required_instance=""
  local gpu_limit="" mem_limit="" mem_req="" cpu_limit="" cpu_req=""

  # Resolve target to model info
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    local idx=$((target - 1))
    if [[ $idx -lt 0 || $idx -ge ${#MODELS[@]} ]]; then
      echo -e "${RED}Invalid tier number. Use 1-${#MODELS[@]}${NC}"
      exit 1
    fi
    IFS='|' read -r model_tag model_name _ min_gpus required_instance gpu_limit mem_limit mem_req cpu_limit cpu_req _ <<< "${MODELS[$idx]}"
  else
    model_tag="$target"
    model_name="$target"
    # Look up in MODELS array
    local found=false
    for model_info in "${MODELS[@]}"; do
      IFS='|' read -r m_tag m_name _ m_gpus m_inst m_gl m_ml m_mr m_cl m_cr _ <<< "$model_info"
      if [[ "$m_tag" == "$target" ]]; then
        model_name="$m_name"
        min_gpus="$m_gpus"
        required_instance="$m_inst"
        gpu_limit="$m_gl"
        mem_limit="$m_ml"
        mem_req="$m_mr"
        cpu_limit="$m_cl"
        cpu_req="$m_cr"
        found=true
        break
      fi
    done
    if [[ "$found" != "true" ]]; then
      echo -e "${RED}Unknown model: $target${NC}"
      echo -e "Run ${CYAN}$0 list${NC} to see available tiers"
      exit 1
    fi
  fi

  print_header

  # ── Step 1: Validate NodePool ──
  echo -e "${BOLD}[1/7] Validating NodePool${NC}"
  if ! check_nodepool "$min_gpus" "$required_instance"; then
    exit 1
  fi
  echo -e "  ${GREEN}✓${NC} NodePool allows ${required_instance} (GPU limit ≥ ${min_gpus})"
  echo ""

  # ── Step 2: Check if resources already match ──
  echo -e "${BOLD}[2/7] Checking current resources${NC}"
  local current_res
  current_res=$(get_current_resources)
  local cur_gpu
  cur_gpu=$(echo "$current_res" | cut -d'|' -f1)
  local needs_patch=true
  local cold_start=false

  # Check if Ollama is at 0 replicas (KEDA scaled to zero)
  local current_replicas
  current_replicas=$(kubectl get deployment ollama -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [[ "$current_replicas" == "0" ]]; then
    cold_start=true
    echo -e "  ${YELLOW}⚠${NC}  Ollama at 0 replicas (KEDA scaled to zero) — cold start"
  fi

  if [[ "$cur_gpu" == "$gpu_limit" ]]; then
    echo -e "  ${GREEN}✓${NC} Deployment already has ${gpu_limit} GPU — skipping patch"
    needs_patch=false
  else
    echo -e "  ${YELLOW}→${NC} Current: ${cur_gpu} GPU → Target: ${gpu_limit} GPU"
  fi
  echo ""

  # ── Step 3: Pause KEDA ──
  echo -e "${BOLD}[3/7] Pausing KEDA${NC}"
  pause_keda
  echo ""

  # ── Step 4: Patch deployment (if needed) ──
  if [[ "$needs_patch" == "true" ]]; then
    echo -e "${BOLD}[4/7] Patching deployment${NC}"
    patch_deployment "$gpu_limit" "$mem_limit" "$mem_req" "$cpu_limit" "$cpu_req"
    echo ""

    # If cold start, scale to 1 after patching (pod doesn't exist yet)
    if $cold_start; then
      echo -e "${BOLD}[5/7] Scaling from zero + waiting for rollout${NC}"
      echo -e "  ${YELLOW}⟳${NC}  Scaling Ollama to 1 replica..."
      kubectl scale deployment ollama -n "$NAMESPACE" --replicas=1
      echo -e "  ${GREEN}✓${NC} Scaled to 1 — Karpenter provisioning ${required_instance}..."
    else
      echo -e "${BOLD}[5/7] Waiting for rollout${NC}"
    fi
    wait_for_rollout

    # Update pod reference after rollout
    OLLAMA_POD=""
    get_pod

    # Kill any stale port-forward and restart
    pkill -f "kubectl port-forward.*ollama.*11434" 2>/dev/null || true
    sleep 2
  else
    # Even if no patch needed, scale up if at zero
    if $cold_start; then
      echo -e "${BOLD}[4/7] Scaling from zero${NC}"
      kubectl scale deployment ollama -n "$NAMESPACE" --replicas=1
      echo -e "  ${GREEN}✓${NC} Scaled to 1 — Karpenter provisioning..."
      echo ""
      echo -e "${BOLD}[5/7] Waiting for rollout${NC}"
      wait_for_rollout
      OLLAMA_POD=""
      get_pod
      pkill -f "kubectl port-forward.*ollama.*11434" 2>/dev/null || true
      sleep 2
    else
      echo -e "${BOLD}[4/7] Patch — skipped${NC}"
      echo -e "${BOLD}[5/7] Rollout — skipped${NC}"
    fi
  fi
  echo ""

  # ── Step 6: Load model ──
  echo -e "${BOLD}[6/7] Loading model${NC}"
  check_port_forward

  # Check if model is downloaded
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

  # Unload current model if different
  local current
  current=$(get_current_model)
  if [[ -n "$current" && "$current" != "$model_tag" ]]; then
    echo -e "  ${YELLOW}⏏${NC}  Unloading current model ($current)..."
    curl -s "$OLLAMA_URL/api/generate" -d "{\"model\": \"$current\", \"keep_alive\": 0}" >/dev/null 2>&1
    sleep 1
    echo -e "  ${GREEN}✓${NC} Unloaded"
  fi

  # Load and warm up
  echo -e "  ${YELLOW}⟳${NC}  Loading $model_tag into GPU memory..."
  curl -s "$OLLAMA_URL/api/generate" -d "{\"model\": \"$model_tag\", \"prompt\": \"hi\", \"options\": {\"num_predict\": 1}}" >/dev/null 2>&1
  echo -e "  ${GREEN}✓${NC} Model loaded and ready"
  echo ""

  # ── Step 7: Sync WebUI model list ──
  echo -e "${BOLD}[7/7] Syncing WebUI model list${NC}"
  sync_webui_models "$gpu_limit" "$model_tag"
  echo ""

  # ── Resume KEDA ──
  unpause_keda
  echo ""

  # Show final state
  local node_info
  node_info=$(get_node_info)
  local final_instance
  final_instance=$(echo "$node_info" | cut -d'|' -f1)
  local final_gpus
  final_gpus=$(echo "$node_info" | cut -d'|' -f2)

  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  Switch complete!                                            ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Model:     ${CYAN}$model_tag${NC}"
  echo -e "  Instance:  ${CYAN}$final_instance${NC} (${final_gpus}x GPU)"
  echo -e "  Resources: ${CYAN}${gpu_limit} GPU, ${mem_limit} mem, ${cpu_limit} CPU${NC}"
  echo -e "  KEDA:      ${GREEN}active${NC} (scales to zero after 15 min idle)"
  echo ""
  echo -e "  Use with Claude Code: ${CYAN}claude --model $model_tag${NC}"
  echo ""
}

cmd_pull_all() {
  print_header
  get_pod
  check_port_forward

  echo -e "${BOLD}Downloading all compatible model tiers...${NC}"
  echo ""

  # Check current GPU capacity
  local node_info
  node_info=$(get_node_info)
  local current_gpus
  current_gpus=$(echo "$node_info" | cut -d'|' -f2)
  current_gpus="${current_gpus:-0}"

  local skipped=0
  for model_info in "${MODELS[@]}"; do
    IFS='|' read -r tag name vram min_gpus req_instance _ _ _ _ _ desc <<< "$model_info"

    if [[ "$current_gpus" -lt "$min_gpus" ]]; then
      echo -e "  ${RED}✗${NC} Skipping ${CYAN}$name${NC} ($tag)"
      echo -e "    Requires ${CYAN}$req_instance${NC} (${min_gpus}x GPU) — current node has ${current_gpus}x GPU"
      echo -e "    Switch to Tier 3 first: ${CYAN}./switch-model.sh use 3${NC}"
      echo ""
      ((skipped++))
      continue
    fi

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

  if [[ $skipped -gt 0 ]]; then
    echo -e "${YELLOW}$skipped tier(s) skipped — switch to that tier first to download its model.${NC}"
  else
    echo -e "${GREEN}${BOLD}All models downloaded!${NC}"
  fi
}

# ============================================================
# Main
# ============================================================
cmd="${1:-help}"

case "$cmd" in
  status|s)
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
    # Don't require a running pod — cmd_use handles cold start (0 replicas)
    cmd_use "$2"
    ;;
  pull-all|download)
    get_pod
    cmd_pull_all
    ;;
  help|--help|-h|*)
    print_header
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${CYAN}list${NC}              Show available model tiers with hardware requirements"
    echo -e "  ${CYAN}status${NC}            Show current tier, hardware, node, and models"
    echo -e "  ${CYAN}use <tier|tag>${NC}    Switch to a model tier (patches resources + loads model)"
    echo -e "  ${CYAN}pull-all${NC}          Download all compatible model tiers (pre-cache)"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  ${CYAN}$0 status${NC}             → Check current tier and hardware"
    echo -e "  ${CYAN}$0 use 1${NC}              → Tier 1 fallback  (g5.xlarge,  ~3 min)"
    echo -e "  ${CYAN}$0 use 2${NC}              → Tier 2 coder     (g5.xlarge,  ~3 min)"
    echo -e "  ${CYAN}$0 use 3${NC}              → Tier 3 flagship  (g5.12xlarge, ~5 min)"
    echo -e "  ${CYAN}$0 use qwen3.5:27b${NC}    → Switch by exact model tag"
    echo ""
    echo -e "${BOLD}How Flex Mode Works:${NC}"
    echo -e "  The GPU NodePool ceiling allows both g5.xlarge and g5.12xlarge."
    echo -e "  When you switch tiers, the script:"
    echo -e "    1. Pauses KEDA (prevents scale-to-zero during switch)"
    echo -e "    2. Patches Ollama deployment resources (GPU, memory, CPU)"
    echo -e "    3. Karpenter auto-provisions the right instance type"
    echo -e "    4. Loads and warms up the model"
    echo -e "    5. Resumes KEDA (scales to zero after 15 min idle)"
    echo ""
    echo -e "  ${BOLD}Cost:${NC} You only pay for the instance while it's running."
    echo -e "  Default (Tier 1) is the cheapest option. Tier 3 only costs"
    echo -e "  more while actively in use. KEDA + Karpenter handle teardown."
    echo ""
    ;;
esac
