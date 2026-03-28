#!/bin/bash
# delete-stack.sh — Complete teardown of the Ollama-on-EKS stack
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Destroys all AWS resources in the correct order to avoid orphaned NLBs,
# ENIs, and security groups that block VPC deletion. Handles Terraform
# errored state, session expiry, and retries.
#
# Why ordered teardown matters:
#   - Istio Gateway creates NLBs — must be deleted before VPC Link + subnets
#   - CloudFront VPC Origins reference the NLB — must be removed first
#   - LB Controller creates security groups + ENIs — orphaned ones block VPC deletion
#   - Helm uninstall can timeout during terraform destroy, leaving dangling resources
#   - AWS sessions expire mid-destroy, creating errored.tfstate that must be recovered
#
# Usage:
#   ./scripts/delete-stack.sh                 # Interactive teardown with confirmation
#   ./scripts/delete-stack.sh --force          # Skip confirmation prompt
#   ./scripts/delete-stack.sh --skip-terraform # K8s + AWS cleanup only (no terraform destroy)
#   ./scripts/delete-stack.sh --help           # Show usage
#
# Phases:
#   1. Pre-flight checks (AWS creds, kubectl, terraform state)
#   2. Scale down workloads (release GPU nodes)
#   3. Clean up K8s resources that create AWS resources (Gateway, NLBs, ArgoCD)
#   4. Terraform destroy (with retry logic for session expiry)
#   5. Clean up orphaned AWS resources (ENIs, security groups, NLBs)
#   6. Verify clean teardown

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

REGION="ap-southeast-2"
CLUSTER_NAME="eks-ollama-dev"
PROJECT_TAG="Ollama-Private-LLM"
MAX_TERRAFORM_RETRIES=3

# Parse arguments
FORCE=false
SKIP_TERRAFORM=false
for arg in "$@"; do
    case "$arg" in
        --force)          FORCE=true ;;
        --skip-terraform) SKIP_TERRAFORM=true ;;
        --help|-h)
            echo "Usage: $0 [--force] [--skip-terraform]"
            echo "  --force          Skip confirmation prompt"
            echo "  --skip-terraform Skip terraform destroy (K8s + AWS cleanup only)"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--force] [--skip-terraform]"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Logging
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_FILE="${TERRAFORM_DIR}/delete-stack-${TIMESTAMP}.log"

log()   { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
step()  {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

# Run a command, log output, but do not exit on failure (for cleanup commands)
run_safe() {
    local desc="$1"
    shift
    log "  $desc"
    if "$@" >> "$LOG_FILE" 2>&1; then
        return 0
    else
        local rc=$?
        warn "  Command failed (rc=$rc): $*"
        return $rc
    fi
}

# Wait for a condition with timeout. Usage: wait_for <description> <timeout_sec> <command ...>
wait_for() {
    local desc="$1"
    local timeout="$2"
    shift 2
    local elapsed=0
    local interval=10

    while [ $elapsed -lt "$timeout" ]; do
        if "$@" >> "$LOG_FILE" 2>&1; then
            log "  $desc — done"
            return 0
        fi
        echo -ne "\r  ${DIM}[${elapsed}s/${timeout}s] Waiting: ${desc}...${NC}    "
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    warn "  Timed out after ${timeout}s: ${desc}"
    return 1
}

# ==============================================================================
# Phase 0: Pre-flight Checks
# ==============================================================================
preflight_checks() {
    step "Phase 0: Pre-flight checks"

    local failed=0

    # Check required tools
    for tool in aws terraform kubectl; do
        if command -v "$tool" > /dev/null 2>&1; then
            log "$tool: found"
        else
            error "$tool: NOT FOUND"
            failed=$((failed + 1))
        fi
    done

    if [ $failed -gt 0 ]; then
        error "Missing $failed required tool(s). Install them and retry."
        exit 1
    fi

    # Check AWS credentials
    log "Verifying AWS credentials..."
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    if [ -z "$ACCOUNT_ID" ]; then
        error "AWS credentials not configured or expired."
        error "Run: aws sso login --profile <your-profile>"
        exit 1
    fi
    CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
    log "AWS Account: ${ACCOUNT_ID}"
    log "Identity:    ${CALLER_ARN}"

    # Check kubectl access
    log "Checking kubectl access..."
    KUBECTL_OK=false
    if kubectl cluster-info > /dev/null 2>&1; then
        log "kubectl: connected to cluster"
        KUBECTL_OK=true
    else
        warn "kubectl: cannot reach cluster (may already be deleted)"
        warn "K8s cleanup phases will be skipped"
    fi

    # Check terraform state
    log "Checking Terraform state..."
    if [ -d "$TERRAFORM_DIR" ]; then
        cd "$TERRAFORM_DIR"
        if terraform state list > /dev/null 2>&1; then
            RESOURCE_COUNT=$(terraform state list 2>/dev/null | wc -l | tr -d ' ')
            log "Terraform state: ${RESOURCE_COUNT} resources tracked"
        else
            warn "Terraform state not accessible (backend may be unreachable)"
        fi
        cd "$REPO_DIR"
    else
        error "Terraform directory not found: ${TERRAFORM_DIR}"
        exit 1
    fi

    # Retrieve VPC ID from Terraform output (needed for orphan cleanup later)
    VPC_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw vpc_id 2>/dev/null || echo "")
    if [ -n "$VPC_ID" ]; then
        log "VPC ID: ${VPC_ID}"
    else
        warn "Could not read VPC ID from Terraform outputs"
        # Try to find by tag
        VPC_ID=$(aws ec2 describe-vpcs \
            --region "$REGION" \
            --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
            --query 'Vpcs[0].VpcId' \
            --output text 2>/dev/null || echo "None")
        if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
            log "VPC ID (found by tag): ${VPC_ID}"
        else
            VPC_ID=""
            warn "No VPC found — orphan cleanup will be limited"
        fi
    fi
}

# ==============================================================================
# Confirmation
# ==============================================================================
confirm_delete() {
    if [ "$FORCE" = "true" ]; then
        log "Skipping confirmation (--force)"
        return
    fi

    echo ""
    echo -e "${RED}${BOLD}  WARNING: This will permanently destroy the entire Ollama-on-EKS stack.${NC}"
    echo ""
    echo "  Resources to be deleted:"
    echo "    - EKS cluster:          ${CLUSTER_NAME}"
    echo "    - VPC:                   ${VPC_ID:-unknown}"
    echo "    - CloudFront + WAF:      distribution + web ACL"
    echo "    - API Gateway:           REST API + VPC Link"
    echo "    - Cognito:               user pools + app clients"
    echo "    - Managed Grafana + AMP: workspace + remote write"
    echo "    - S3 buckets:            portal + login assets"
    echo "    - All K8s workloads:     Ollama, ArgoCD, Istio, monitoring"
    echo ""
    echo "  Region:    ${REGION}"
    echo "  Account:   ${ACCOUNT_ID}"
    if [ -n "${RESOURCE_COUNT:-}" ]; then
        echo "  TF state:  ${RESOURCE_COUNT} resources"
    fi
    echo "  Log file:  ${LOG_FILE}"
    echo ""

    read -r -p "  Type 'destroy' to confirm: " confirm
    if [ "$confirm" != "destroy" ]; then
        echo ""
        echo "  Aborted."
        exit 0
    fi
    echo ""
}

# ==============================================================================
# Phase 1: Scale Down Workloads
# ==============================================================================
scale_down_workloads() {
    step "Phase 1: Scaling down workloads (release GPU nodes)"

    if [ "$KUBECTL_OK" != "true" ]; then
        warn "Skipping — kubectl not connected"
        return
    fi

    # Scale Ollama to 0
    log "Scaling Ollama deployment to 0 replicas..."
    if kubectl get deployment ollama -n ollama > /dev/null 2>&1; then
        kubectl scale deployment ollama -n ollama --replicas=0 >> "$LOG_FILE" 2>&1 || true
        log "Ollama scaled to 0"
    else
        warn "Ollama deployment not found — may already be gone"
    fi

    # Delete GPU NodePool to force immediate node termination
    # (Karpenter's consolidateAfter would otherwise wait 30 min)
    log "Deleting GPU NodePool (force immediate GPU node termination)..."
    if kubectl get nodepool gpu-ollama > /dev/null 2>&1; then
        kubectl delete nodepool gpu-ollama --timeout=60s >> "$LOG_FILE" 2>&1 || true
        log "GPU NodePool deleted"
    else
        warn "GPU NodePool not found — may already be gone"
    fi

    # Wait briefly for GPU nodes to start draining
    log "Waiting for GPU nodes to begin termination..."
    sleep 15

    # Check remaining GPU nodes
    GPU_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "g5\." || true)
    GPU_NODES="${GPU_NODES:-0}"
    if [ "$GPU_NODES" -gt 0 ]; then
        warn "${GPU_NODES} GPU node(s) still present — they will terminate during cluster deletion"
    else
        log "No GPU nodes remaining"
    fi
}

# ==============================================================================
# Phase 2: Clean Up K8s Resources That Create AWS Resources
# ==============================================================================
cleanup_k8s_resources() {
    step "Phase 2: Cleaning up K8s resources that create AWS resources"

    if [ "$KUBECTL_OK" != "true" ]; then
        warn "Skipping — kubectl not connected"
        return
    fi

    # Step 2a: Delete all HTTPRoutes (they reference the Gateway)
    log "Deleting HTTPRoutes across all namespaces..."
    kubectl delete httproutes --all-namespaces --all --timeout=30s >> "$LOG_FILE" 2>&1 || true

    # Step 2b: Delete the Istio Gateway (this owns the NLB-creating Service)
    log "Deleting Istio Gateway..."
    if kubectl get gateway ollama-gateway -n istio-ingress > /dev/null 2>&1; then
        kubectl delete gateway ollama-gateway -n istio-ingress --timeout=60s >> "$LOG_FILE" 2>&1 || true
        log "Gateway deleted"
    else
        warn "Gateway not found — may already be gone"
    fi

    # Step 2c: Delete any remaining Services of type LoadBalancer
    log "Deleting LoadBalancer Services..."
    LB_SERVICES=$(kubectl get svc --all-namespaces -o json 2>/dev/null | \
        python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data.get('items', []):
        spec = item.get('spec', {})
        if spec.get('type') == 'LoadBalancer':
            ns = item['metadata']['namespace']
            name = item['metadata']['name']
            print(f'{ns}/{name}')
except:
    pass
" 2>/dev/null || echo "")

    if [ -n "$LB_SERVICES" ]; then
        echo "$LB_SERVICES" | while IFS='/' read -r ns name; do
            log "  Deleting LB service: ${ns}/${name}"
            kubectl delete svc "$name" -n "$ns" --timeout=60s >> "$LOG_FILE" 2>&1 || true
        done
    else
        log "No LoadBalancer services found"
    fi

    # Step 2d: Wait for NLBs to be fully deleted
    log "Waiting for cluster-tagged NLBs to be deleted by AWS..."
    wait_for_nlb_deletion

    # Step 2e: Delete ArgoCD applications (stop reconciliation fighting cleanup)
    log "Deleting ArgoCD applications (prevent reconciliation)..."
    if kubectl get applications -n argocd > /dev/null 2>&1; then
        # Remove finalizers first to prevent ArgoCD from blocking deletion
        APPS=$(kubectl get applications -n argocd -o name 2>/dev/null || echo "")
        if [ -n "$APPS" ]; then
            echo "$APPS" | while read -r app; do
                kubectl patch "$app" -n argocd --type merge -p '{"metadata":{"finalizers":null}}' >> "$LOG_FILE" 2>&1 || true
            done
            kubectl delete applications --all -n argocd --timeout=60s >> "$LOG_FILE" 2>&1 || true
            log "ArgoCD applications deleted"
        fi
    else
        warn "ArgoCD namespace not found — may already be gone"
    fi

    # Step 2f: Delete cert-manager resources (CRDs can block namespace deletion)
    log "Deleting cert-manager resources..."
    kubectl delete certificates --all-namespaces --all --timeout=30s >> "$LOG_FILE" 2>&1 || true
    kubectl delete clusterissuers --all --timeout=30s >> "$LOG_FILE" 2>&1 || true

    # Step 2g: Delete API Gateway REST API + VPC Link (blocks NLB + IGW deletion)
    # VPC Link holds the NLB, which holds ENIs, which block IGW detach.
    # Must be deleted BEFORE terraform destroy to avoid 20-min IGW timeout.
    log "Cleaning up API Gateway REST API and VPC Links..."
    REST_APIS=$(aws apigateway get-rest-apis --region "$REGION" \
        --query "items[?contains(name, 'ollama')].id" --output text 2>/dev/null || echo "")
    for api_id in $REST_APIS; do
        if [ -n "$api_id" ]; then
            log "  Deleting REST API: ${api_id}"
            aws apigateway delete-rest-api --rest-api-id "$api_id" --region "$REGION" >> "$LOG_FILE" 2>&1 || true
        fi
    done

    sleep 5

    VPC_LINKS=$(aws apigateway get-vpc-links --region "$REGION" \
        --query "items[?contains(name, 'ollama')].id" --output text 2>/dev/null || echo "")
    for link_id in $VPC_LINKS; do
        if [ -n "$link_id" ]; then
            log "  Deleting VPC Link: ${link_id}"
            aws apigateway delete-vpc-link --vpc-link-id "$link_id" --region "$REGION" >> "$LOG_FILE" 2>&1 || true
        fi
    done

    if [ -n "$VPC_LINKS" ]; then
        log "  Waiting for VPC Link deletion (up to 60s)..."
        local vl_wait=0
        while [ $vl_wait -lt 60 ]; do
            REMAINING=$(aws apigateway get-vpc-links --region "$REGION" \
                --query "items[?contains(name, 'ollama')].id" --output text 2>/dev/null || echo "")
            if [ -z "$REMAINING" ]; then
                log "  VPC Links deleted"
                break
            fi
            sleep 10
            vl_wait=$((vl_wait + 10))
        done
    fi
}

# Wait for all NLBs tagged with the cluster to be deleted
wait_for_nlb_deletion() {
    local timeout=300
    local elapsed=0
    local interval=15

    while [ $elapsed -lt $timeout ]; do
        NLB_COUNT=$(aws elbv2 describe-load-balancers \
            --region "$REGION" \
            --query "LoadBalancers[?Type=='network'].LoadBalancerArn" \
            --output json 2>/dev/null | \
            python3 -c "
import sys, json, subprocess
arns = json.load(sys.stdin)
count = 0
for arn in arns:
    result = subprocess.run(
        ['aws', 'elbv2', 'describe-tags', '--region', '${REGION}', '--resource-arns', arn],
        capture_output=True, text=True
    )
    try:
        tags = json.loads(result.stdout)
        for desc in tags.get('TagDescriptions', []):
            for tag in desc.get('Tags', []):
                if tag.get('Key', '') in ('elbv2.k8s.aws/cluster', 'kubernetes.io/cluster/${CLUSTER_NAME}'):
                    count += 1
                    break
    except:
        pass
print(count)
" 2>/dev/null || echo "0")

        if [ "$NLB_COUNT" = "0" ]; then
            log "  All cluster-tagged NLBs deleted"
            return 0
        fi

        echo -ne "\r  ${DIM}[${elapsed}s/${timeout}s] ${NLB_COUNT} NLB(s) still deleting...${NC}    "
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    warn "  ${NLB_COUNT} NLB(s) still present after ${timeout}s timeout"
    warn "  Continuing — terraform destroy or orphan cleanup will handle them"
}

# ==============================================================================
# Phase 3: Terraform Destroy (with retry logic)
# ==============================================================================
terraform_destroy() {
    step "Phase 3: Terraform destroy"

    if [ "$SKIP_TERRAFORM" = "true" ]; then
        warn "Skipping terraform destroy (--skip-terraform)"
        return
    fi

    cd "$TERRAFORM_DIR"

    local attempt=0
    local success=false

    while [ $attempt -lt $MAX_TERRAFORM_RETRIES ]; do
        attempt=$((attempt + 1))
        log "Terraform destroy — attempt ${attempt}/${MAX_TERRAFORM_RETRIES}"

        # Check for errored.tfstate from a previous failed run
        if [ -f "errored.tfstate" ]; then
            warn "Found errored.tfstate from a previous failed run"
            handle_errored_state
        fi

        # Run terraform init (in case backend config changed)
        log "Running terraform init..."
        if ! terraform init -input=false >> "$LOG_FILE" 2>&1; then
            error "terraform init failed — check ${LOG_FILE}"
            if [ $attempt -lt $MAX_TERRAFORM_RETRIES ]; then
                prompt_reauth
                continue
            fi
            break
        fi

        # Run terraform destroy
        log "Running terraform destroy -auto-approve..."
        log "This may take 15-30 minutes. Tail the log:"
        log "  tail -f ${LOG_FILE}"
        echo ""

        if terraform destroy -auto-approve >> "$LOG_FILE" 2>&1; then
            success=true
            log "Terraform destroy completed successfully"
            break
        else
            local rc=$?
            error "Terraform destroy failed (rc=$rc)"

            # Check for errored state
            if [ -f "errored.tfstate" ]; then
                warn "errored.tfstate created — state will be recovered on next attempt"
            fi

            # Check for state lock error
            LOCK_ID=$(grep -o 'ID: *[a-f0-9-]*' "$LOG_FILE" | tail -1 | sed 's/ID: *//' || echo "")
            if [ -n "$LOCK_ID" ]; then
                warn "State lock detected — ID: ${LOCK_ID}"
                log "Attempting force-unlock..."
                terraform force-unlock -force "$LOCK_ID" >> "$LOG_FILE" 2>&1 || true
            fi

            if [ $attempt -lt $MAX_TERRAFORM_RETRIES ]; then
                echo ""
                warn "Destroy failed. This is often caused by:"
                warn "  1. AWS session expired (re-authenticate and retry)"
                warn "  2. Resource dependency stuck (NLB still deleting)"
                warn "  3. Timeout on Helm uninstall"
                echo ""
                prompt_reauth
            fi
        fi
    done

    # Reset terraform.tfvars values that are discovered at deploy-time.
    # These become stale after destroy and MUST be empty for a clean recreate.
    # deploy.sh will re-discover them automatically.
    if [ "$success" = "true" ]; then
        log "Resetting deploy-time values in terraform.tfvars for clean recreate..."
        sed -i.bak 's|^nlb_arn .*=.*|nlb_arn      = ""|' "$TERRAFORM_DIR/terraform.tfvars"
        sed -i.bak 's|^nlb_dns_name .*=.*|nlb_dns_name = ""|' "$TERRAFORM_DIR/terraform.tfvars"
        sed -i.bak 's|^cloudfront_domain = .*|cloudfront_domain = ""|' "$TERRAFORM_DIR/terraform.tfvars"
        rm -f "$TERRAFORM_DIR/terraform.tfvars.bak"
        log "terraform.tfvars reset — ready for clean recreate"
    fi

    cd "$REPO_DIR"

    if [ "$success" != "true" ]; then
        error "Terraform destroy failed after ${MAX_TERRAFORM_RETRIES} attempts"
        error "Review logs: ${LOG_FILE}"
        error "You may need to manually delete resources and run: terraform state rm <resource>"
        # Continue to orphan cleanup — it can help even if TF failed
    fi
}

# Handle errored.tfstate recovery
handle_errored_state() {
    log "Recovering Terraform state from errored.tfstate..."

    # Force-unlock if there is a stale lock
    LOCK_ID=$(grep -o 'ID: *[a-f0-9-]*' "$LOG_FILE" | tail -1 | sed 's/ID: *//' || echo "")
    if [ -n "$LOCK_ID" ]; then
        log "Force-unlocking stale lock: ${LOCK_ID}"
        terraform force-unlock -force "$LOCK_ID" >> "$LOG_FILE" 2>&1 || true
    fi

    # Push the errored state (only if newer than remote)
    log "Pushing errored.tfstate to backend..."
    if terraform state push errored.tfstate >> "$LOG_FILE" 2>&1; then
        log "State recovered successfully"
        rm -f errored.tfstate
    else
        warn "Could not push errored.tfstate (may be stale) — removing and using remote state"
        rm -f errored.tfstate
    fi
}

# Prompt for AWS re-authentication between retries
prompt_reauth() {
    if [ "$FORCE" = "true" ]; then
        warn "AWS credentials may have expired. --force mode: waiting 30s then retrying..."
        sleep 30
        return
    fi

    echo ""
    echo -e "${YELLOW}${BOLD}  AWS credentials may have expired.${NC}"
    echo "  Re-authenticate in another terminal, then press Enter to retry."
    echo "  Example: aws sso login --profile <your-profile>"
    echo ""
    read -r -p "  Press Enter when ready (or Ctrl-C to abort)... "
    echo ""

    # Verify credentials after re-auth
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        error "AWS credentials still not valid"
    else
        log "AWS credentials verified"
    fi
}

# ==============================================================================
# Phase 4: Clean Up Orphaned AWS Resources
# ==============================================================================
cleanup_orphaned_resources() {
    step "Phase 4: Cleaning up orphaned AWS resources"

    if [ -z "$VPC_ID" ]; then
        warn "No VPC ID available — looking up by project tag..."
        VPC_ID=$(aws ec2 describe-vpcs \
            --region "$REGION" \
            --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
            --query 'Vpcs[0].VpcId' \
            --output text 2>/dev/null || echo "None")
        if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
            log "No VPC found with project tag — VPC already deleted or never tagged"
            VPC_ID=""
        else
            log "Found VPC: ${VPC_ID}"
        fi
    fi

    cleanup_orphaned_nlbs
    cleanup_orphaned_target_groups

    if [ -n "$VPC_ID" ]; then
        cleanup_orphaned_enis
        cleanup_orphaned_security_groups
    else
        warn "Skipping ENI and security group cleanup — no VPC ID"
    fi
}

# Delete orphaned NLBs tagged with our cluster
cleanup_orphaned_nlbs() {
    log "Checking for orphaned NLBs..."

    NLB_ARNS=$(aws elbv2 describe-load-balancers \
        --region "$REGION" \
        --query "LoadBalancers[?Type=='network'].LoadBalancerArn" \
        --output json 2>/dev/null | \
        python3 -c "
import sys, json, subprocess
arns = json.load(sys.stdin)
cluster_arns = []
for arn in arns:
    result = subprocess.run(
        ['aws', 'elbv2', 'describe-tags', '--region', '${REGION}', '--resource-arns', arn],
        capture_output=True, text=True
    )
    try:
        tags = json.loads(result.stdout)
        for desc in tags.get('TagDescriptions', []):
            for tag in desc.get('Tags', []):
                key = tag.get('Key', '')
                if key == 'elbv2.k8s.aws/cluster' or key.startswith('kubernetes.io/cluster/'):
                    cluster_arns.append(arn)
                    break
    except:
        pass
for a in cluster_arns:
    print(a)
" 2>/dev/null || echo "")

    if [ -z "$NLB_ARNS" ]; then
        log "No orphaned NLBs found"
        return
    fi

    echo "$NLB_ARNS" | while read -r arn; do
        if [ -n "$arn" ]; then
            log "  Deleting orphaned NLB: ${arn}"
            # Delete listeners first
            LISTENER_ARNS=$(aws elbv2 describe-listeners \
                --region "$REGION" \
                --load-balancer-arn "$arn" \
                --query 'Listeners[].ListenerArn' \
                --output text 2>/dev/null || echo "")
            for listener in $LISTENER_ARNS; do
                aws elbv2 delete-listener --region "$REGION" --listener-arn "$listener" >> "$LOG_FILE" 2>&1 || true
            done
            aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" >> "$LOG_FILE" 2>&1 || true
        fi
    done

    log "Waiting for orphaned NLBs to finish deleting..."
    sleep 30
}

# Delete orphaned target groups
cleanup_orphaned_target_groups() {
    log "Checking for orphaned target groups..."

    TG_ARNS=$(aws elbv2 describe-target-groups \
        --region "$REGION" \
        --query 'TargetGroups[].TargetGroupArn' \
        --output json 2>/dev/null | \
        python3 -c "
import sys, json, subprocess
arns = json.load(sys.stdin)
orphaned = []
for arn in arns:
    result = subprocess.run(
        ['aws', 'elbv2', 'describe-tags', '--region', '${REGION}', '--resource-arns', arn],
        capture_output=True, text=True
    )
    try:
        tags = json.loads(result.stdout)
        for desc in tags.get('TagDescriptions', []):
            for tag in desc.get('Tags', []):
                key = tag.get('Key', '')
                if key == 'elbv2.k8s.aws/cluster' or key.startswith('kubernetes.io/cluster/'):
                    orphaned.append(arn)
                    break
    except:
        pass
for a in orphaned:
    print(a)
" 2>/dev/null || echo "")

    if [ -z "$TG_ARNS" ]; then
        log "No orphaned target groups found"
        return
    fi

    echo "$TG_ARNS" | while read -r arn; do
        if [ -n "$arn" ]; then
            log "  Deleting orphaned target group: ${arn}"
            aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn" >> "$LOG_FILE" 2>&1 || true
        fi
    done
}

# Delete orphaned ENIs (attached to NLBs/VPC Origins that are now gone)
cleanup_orphaned_enis() {
    log "Checking for orphaned ENIs in VPC ${VPC_ID}..."

    # Find ENIs that are "available" (detached) in our VPC
    ORPHANED_ENIS=$(aws ec2 describe-network-interfaces \
        --region "$REGION" \
        --filters \
            "Name=vpc-id,Values=${VPC_ID}" \
            "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text 2>/dev/null || echo "")

    if [ -z "$ORPHANED_ENIS" ] || [ "$ORPHANED_ENIS" = "None" ]; then
        log "No orphaned ENIs found"
        return
    fi

    local count=0
    for eni in $ORPHANED_ENIS; do
        log "  Deleting orphaned ENI: ${eni}"
        aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" >> "$LOG_FILE" 2>&1 || true
        count=$((count + 1))
    done
    log "Deleted ${count} orphaned ENI(s)"

    # Also handle ENIs that are still "in-use" but describe as ELB-managed
    log "Checking for stuck ELB-managed ENIs..."
    STUCK_ENIS=$(aws ec2 describe-network-interfaces \
        --region "$REGION" \
        --filters \
            "Name=vpc-id,Values=${VPC_ID}" \
            "Name=status,Values=in-use" \
            "Name=description,Values=ELB*" \
        --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Attach:Attachment.AttachmentId}' \
        --output json 2>/dev/null || echo "[]")

    STUCK_COUNT=$(echo "$STUCK_ENIS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len(data))
" 2>/dev/null || echo "0")

    if [ "$STUCK_COUNT" -gt 0 ]; then
        warn "  Found ${STUCK_COUNT} stuck ELB-managed ENI(s) — detaching..."
        echo "$STUCK_ENIS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data:
    eni_id = item.get('Id', '')
    attach_id = item.get('Attach', '')
    if eni_id and attach_id:
        print(f'{eni_id} {attach_id}')
" 2>/dev/null | while read -r eni_id attach_id; do
            log "    Detaching ${eni_id} (attachment: ${attach_id})"
            aws ec2 detach-network-interface --region "$REGION" --attachment-id "$attach_id" --force >> "$LOG_FILE" 2>&1 || true
        done

        # Wait for detachment and then delete
        sleep 15
        echo "$STUCK_ENIS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data:
    print(item.get('Id', ''))
" 2>/dev/null | while read -r eni_id; do
            if [ -n "$eni_id" ]; then
                aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni_id" >> "$LOG_FILE" 2>&1 || true
            fi
        done
    fi
}

# Delete orphaned security groups created by the LB controller
cleanup_orphaned_security_groups() {
    log "Checking for orphaned security groups in VPC ${VPC_ID}..."

    # Find SGs tagged with elbv2.k8s.aws/cluster or kubernetes.io/cluster/
    ORPHANED_SGS=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,Tags:Tags}' \
        --output json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for sg in data:
    if sg['Name'] == 'default':
        continue
    tags = sg.get('Tags') or []
    for tag in tags:
        key = tag.get('Key', '')
        if 'elbv2.k8s.aws/cluster' in key or 'kubernetes.io/cluster/' in key:
            print(sg['Id'])
            break
" 2>/dev/null || echo "")

    if [ -z "$ORPHANED_SGS" ]; then
        log "No orphaned security groups found"
        return
    fi

    # Must remove inter-SG rules before deleting
    local count=0
    for sg_id in $ORPHANED_SGS; do
        log "  Revoking ingress/egress rules on: ${sg_id}"

        # Revoke all ingress rules
        INGRESS_RULES=$(aws ec2 describe-security-group-rules \
            --region "$REGION" \
            --filters "Name=group-id,Values=${sg_id}" \
            --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' \
            --output text 2>/dev/null || echo "")
        for rule_id in $INGRESS_RULES; do
            if [ -n "$rule_id" ] && [ "$rule_id" != "None" ]; then
                aws ec2 revoke-security-group-ingress --region "$REGION" \
                    --group-id "$sg_id" --security-group-rule-ids "$rule_id" >> "$LOG_FILE" 2>&1 || true
            fi
        done

        # Revoke all egress rules
        EGRESS_RULES=$(aws ec2 describe-security-group-rules \
            --region "$REGION" \
            --filters "Name=group-id,Values=${sg_id}" \
            --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' \
            --output text 2>/dev/null || echo "")
        for rule_id in $EGRESS_RULES; do
            if [ -n "$rule_id" ] && [ "$rule_id" != "None" ]; then
                aws ec2 revoke-security-group-egress --region "$REGION" \
                    --group-id "$sg_id" --security-group-rule-ids "$rule_id" >> "$LOG_FILE" 2>&1 || true
            fi
        done
    done

    # Now delete the security groups
    for sg_id in $ORPHANED_SGS; do
        log "  Deleting orphaned SG: ${sg_id}"
        aws ec2 delete-security-group --region "$REGION" --group-id "$sg_id" >> "$LOG_FILE" 2>&1 || true
        count=$((count + 1))
    done

    log "Processed ${count} orphaned security group(s)"
}

# ==============================================================================
# Phase 5: Verify Clean Teardown
# ==============================================================================
verify_teardown() {
    step "Phase 5: Verifying clean teardown"

    local issues=0

    # Check EKS cluster is gone
    log "Checking EKS cluster..."
    CLUSTER_STATUS=$(aws eks describe-cluster \
        --region "$REGION" \
        --name "$CLUSTER_NAME" \
        --query 'cluster.status' \
        --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$CLUSTER_STATUS" = "NOT_FOUND" ]; then
        log "EKS cluster ${CLUSTER_NAME}: deleted"
    elif [ "$CLUSTER_STATUS" = "DELETING" ]; then
        warn "EKS cluster ${CLUSTER_NAME}: still deleting"
        issues=$((issues + 1))
    else
        error "EKS cluster ${CLUSTER_NAME}: still exists (status: ${CLUSTER_STATUS})"
        issues=$((issues + 1))
    fi

    # Check VPC is gone
    log "Checking VPC..."
    REMAINING_VPCS=$(aws ec2 describe-vpcs \
        --region "$REGION" \
        --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null || echo "")
    if [ -z "$REMAINING_VPCS" ] || [ "$REMAINING_VPCS" = "None" ]; then
        log "VPC: deleted"
    else
        error "VPC still exists: ${REMAINING_VPCS}"
        issues=$((issues + 1))
    fi

    # Check for remaining NLBs
    log "Checking for remaining NLBs..."
    REMAINING_NLBS=$(aws elbv2 describe-load-balancers \
        --region "$REGION" \
        --query 'LoadBalancers[].LoadBalancerName' \
        --output json 2>/dev/null | \
        python3 -c "
import sys, json
names = json.load(sys.stdin)
for n in names:
    if 'ollama' in n.lower() or 'k8s-' in n.lower():
        print(n)
" 2>/dev/null || echo "")
    if [ -z "$REMAINING_NLBS" ]; then
        log "No project-related NLBs remaining"
    else
        warn "Possible orphaned NLBs: ${REMAINING_NLBS}"
        issues=$((issues + 1))
    fi

    # Check CloudFront distributions
    log "Checking CloudFront distributions..."
    REMAINING_CF=$(aws cloudfront list-distributions \
        --query 'DistributionList.Items[].{Id:Id,Comment:Comment}' \
        --output json 2>/dev/null | \
        python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data is None:
        sys.exit(0)
    for d in data:
        comment = d.get('Comment', '')
        if 'ollama' in comment.lower() or 'private-llm' in comment.lower():
            print(d['Id'])
except:
    pass
" 2>/dev/null || echo "")
    if [ -z "$REMAINING_CF" ]; then
        log "No project-related CloudFront distributions remaining"
    else
        warn "Possible orphaned CloudFront distributions: ${REMAINING_CF}"
        issues=$((issues + 1))
    fi

    # Check for project-tagged resources
    log "Checking for any remaining project-tagged resources..."
    TAGGED_RESOURCES=$(aws resourcegroupstaggingapi get-resources \
        --region "$REGION" \
        --tag-filters "Key=Project,Values=${PROJECT_TAG}" \
        --query 'ResourceTagMappingList[].ResourceARN' \
        --output json 2>/dev/null | \
        python3 -c "
import sys, json
arns = json.load(sys.stdin)
for arn in arns:
    print(arn)
" 2>/dev/null || echo "")

    if [ -z "$TAGGED_RESOURCES" ]; then
        log "No resources with Project=${PROJECT_TAG} tag found"
    else
        TAGGED_COUNT=$(echo "$TAGGED_RESOURCES" | wc -l | tr -d ' ')
        warn "${TAGGED_COUNT} resource(s) still tagged with Project=${PROJECT_TAG}:"
        echo "$TAGGED_RESOURCES" | head -20 | while read -r arn; do
            warn "  ${arn}"
        done
        if [ "$TAGGED_COUNT" -gt 20 ]; then
            warn "  ... and $((TAGGED_COUNT - 20)) more"
        fi
        issues=$((issues + 1))
    fi

    # Summary
    echo ""
    if [ $issues -eq 0 ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  TEARDOWN COMPLETE — all resources deleted${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  TEARDOWN INCOMPLETE — ${issues} issue(s) found${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "  Review the warnings above and the log file:"
        echo "  ${LOG_FILE}"
        echo ""
        echo "  Common fixes:"
        echo "    - NLB still deleting: wait 5-10 min, then re-run with --skip-terraform"
        echo "    - VPC stuck: check for orphaned ENIs/SGs, re-run with --skip-terraform"
        echo "    - CloudFront deleting: distributions take 15-30 min to fully delete"
        echo "    - Tagged resources: may be S3/DynamoDB state resources (safe to keep)"
    fi

    echo ""
    echo "  Log file: ${LOG_FILE}"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================
echo ""
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  Ollama on EKS — Stack Teardown${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Cluster:  ${CLUSTER_NAME}"
echo "  Region:   ${REGION}"
echo "  Log:      ${LOG_FILE}"
echo ""

# Initialize log
echo "=== delete-stack.sh started at $(date) ===" > "$LOG_FILE"
echo "Arguments: $*" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

preflight_checks
confirm_delete
scale_down_workloads
cleanup_k8s_resources
terraform_destroy
cleanup_orphaned_resources
verify_teardown
