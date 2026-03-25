#!/bin/bash
# Deploy Stack A — Fully Air-Gapped Ollama on EKS
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# End-to-end deployment of the air-gapped LLM inference platform:
#   Phase 1: Prerequisites — validate tools, AWS credentials, S3 backend
#   Phase 2: Infrastructure — terraform init + plan + apply
#   Phase 3: Cluster setup — configure kubectl, wait for ArgoCD waves
#   Phase 4: Verification — air-gap compliance checks
#
# Stack A means:
#   - All inference runs on local Ollama/Qwen (zero external API calls)
#   - No Bedrock VPC endpoints, no external model providers
#   - NetworkPolicies enforce air-gap on every namespace
#   - Prompts and source code never leave the AWS account
#
# Usage:
#   ./scripts/deploy-stack-a.sh                # Full deployment
#   ./scripts/deploy-stack-a.sh --plan-only    # Terraform plan only (no apply)
#   ./scripts/deploy-stack-a.sh --skip-infra   # Skip Terraform (cluster already exists)
#
# Prerequisites:
#   - AWS CLI configured (aws sts get-caller-identity works)
#   - Terraform >= 1.0 installed
#   - kubectl installed
#   - helm installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

# Parse arguments
PLAN_ONLY=false
SKIP_INFRA=false
for arg in "$@"; do
    case "$arg" in
        --plan-only)  PLAN_ONLY=true ;;
        --skip-infra) SKIP_INFRA=true ;;
        --help|-h)
            echo "Usage: $0 [--plan-only] [--skip-infra]"
            echo "  --plan-only   Run terraform plan without applying"
            echo "  --skip-infra  Skip Terraform (cluster already deployed)"
            exit 0
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

log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step()  {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ==============================================================================
# Phase 1: Prerequisites
# ==============================================================================
check_prerequisites() {
    step "Phase 1: Checking prerequisites"

    local missing=0

    # Check required tools
    for tool in aws terraform kubectl helm; do
        if command -v "$tool" &>/dev/null; then
            local version
            case "$tool" in
                aws)       version=$(aws --version 2>&1 | head -1) ;;
                terraform) version=$(terraform version -json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['terraform_version'])" 2>/dev/null || terraform version | head -1) ;;
                kubectl)   version=$(kubectl version --client -o json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['clientVersion']['gitVersion'])" 2>/dev/null || echo "installed") ;;
                helm)      version=$(helm version --short 2>/dev/null || echo "installed") ;;
            esac
            log "$tool: ${version}"
        else
            error "$tool: NOT FOUND"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        error "Missing $missing required tool(s). Install them and retry."
        exit 1
    fi

    # Check AWS credentials
    echo ""
    log "Verifying AWS credentials..."
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    if [[ -z "$ACCOUNT_ID" ]]; then
        error "AWS credentials not configured. Run: aws sso login --profile <your-profile>"
        exit 1
    fi
    CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
    log "AWS Account: ${ACCOUNT_ID}"
    log "Identity:    ${CALLER_ARN}"

    # Verify Stack A config
    echo ""
    log "Verifying Stack A configuration..."

    REGION=$(grep '^region' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"//;s/".*//')
    BEDROCK=$(grep '^enable_bedrock' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *//' || echo "false")
    MODEL=$(grep '^ollama_model' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"//;s/".*//')

    log "Region:         ${REGION}"
    log "Bedrock:        ${BEDROCK}"
    log "Default model:  ${MODEL}"

    if [[ "$BEDROCK" == "true" ]]; then
        error "enable_bedrock=true in terraform.tfvars — this is Stack B, not Stack A."
        error "Set enable_bedrock=false for Stack A (air-gapped)."
        exit 1
    fi

    log "Stack A configuration verified"
}

# ==============================================================================
# Phase 1b: S3 Backend Bootstrap
# ==============================================================================
setup_backend() {
    step "Phase 1b: S3 Backend for Terraform State"

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    BUCKET_NAME="ollama-eks-tfstate-${ACCOUNT_ID}"
    TABLE_NAME="ollama-eks-tfstate-lock"
    REGION=$(grep '^region' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"//;s/".*//')

    # Check if backend.tf has placeholder
    if grep -q '<ACCOUNT_ID>' "$TERRAFORM_DIR/backend.tf"; then
        log "Replacing <ACCOUNT_ID> placeholder in backend.tf with ${ACCOUNT_ID}..."
        sed -i.bak "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g" "$TERRAFORM_DIR/backend.tf"
        rm -f "$TERRAFORM_DIR/backend.tf.bak"
        log "backend.tf updated"
    fi

    # Create S3 bucket if it doesn't exist
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        log "S3 bucket already exists: ${BUCKET_NAME}"
    else
        log "Creating S3 bucket: ${BUCKET_NAME}..."
        if [[ "$REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
        else
            aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" \
                --create-bucket-configuration LocationConstraint="$REGION"
        fi

        aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
            --versioning-configuration Status=Enabled

        aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
            --server-side-encryption-configuration \
            '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'

        aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
            --public-access-block-configuration \
            BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

        log "S3 bucket created with versioning + encryption + public access blocked"
    fi

    # Create DynamoDB table if it doesn't exist
    TABLE_EXISTS=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" 2>/dev/null && echo "yes" || echo "no")
    if [[ "$TABLE_EXISTS" == "yes" ]]; then
        log "DynamoDB table already exists: ${TABLE_NAME}"
    else
        log "Creating DynamoDB table: ${TABLE_NAME}..."
        aws dynamodb create-table \
            --table-name "$TABLE_NAME" \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST \
            --region "$REGION"

        aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
        log "DynamoDB table created"
    fi
}

# ==============================================================================
# Phase 2: Terraform Init + Plan + Apply
# ==============================================================================
deploy_infrastructure() {
    step "Phase 2: Deploying infrastructure with Terraform"

    cd "$TERRAFORM_DIR"

    # Terraform init (with backend migration if needed)
    log "Running terraform init..."
    if [[ -f terraform.tfstate ]] && [[ -s terraform.tfstate ]]; then
        log "Local state file found — migrating to S3 backend..."
        terraform init -migrate-state -input=false
    else
        terraform init -input=false
    fi

    # Terraform plan
    echo ""
    log "Running terraform plan..."
    terraform plan -out=tfplan

    if [[ "$PLAN_ONLY" == "true" ]]; then
        log "Plan complete. Run without --plan-only to apply."
        exit 0
    fi

    # Confirm before apply
    echo ""
    echo -e "${YELLOW}${BOLD}  Review the plan above.${NC}"
    read -r -p "  Apply this plan? [y/N] " confirm
    if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
        echo ""
        echo "  Aborted. Plan saved to terraform/tfplan."
        echo "  To apply later: cd terraform && terraform apply tfplan"
        exit 0
    fi

    # Terraform apply (Phase 1 — creates all infrastructure)
    echo ""
    log "Applying Terraform plan..."
    terraform apply tfplan

    # Clean up plan file
    rm -f tfplan

    log "Phase 1 apply complete"

    # Phase 2 — re-apply with CloudFront domain for Cognito callbacks and portal CORS
    # CloudFront domain is only known after first apply (circular dependency with portal S3 origins).
    # Second apply updates: Cognito callback URLs, portal CORS headers, portal Lambda env vars.
    echo ""
    CLOUDFRONT_DOMAIN=$(terraform output -raw cloudfront_domain 2>/dev/null || echo "")
    if [[ -n "$CLOUDFRONT_DOMAIN" ]]; then
        log "CloudFront domain: ${CLOUDFRONT_DOMAIN}"
        log "Updating terraform.tfvars with CloudFront domain for Cognito/portal wiring..."
        sed -i.bak "s|^cloudfront_domain = .*|cloudfront_domain = \"${CLOUDFRONT_DOMAIN}\"|" terraform.tfvars
        rm -f terraform.tfvars.bak

        log "Running Phase 2 apply (Cognito callbacks + portal CORS)..."
        terraform apply -auto-approve 2>&1 | tail -3
        log "Phase 2 apply complete"
    else
        warn "Could not get CloudFront domain — Cognito callbacks will need manual wiring"
    fi

    log "Terraform deployment complete"
    cd "$REPO_DIR"
}

# ==============================================================================
# Phase 2b: Bootstrap Custom NodePools
# ==============================================================================
# EKS Auto Mode uses node_pools=[] (no built-in pools) to avoid c6g.large
# Graviton instances. Custom NodePool/NodeClass files are applied via kubectl
# IMMEDIATELY after EKS creation — before ArgoCD starts. This ensures the
# cluster only ever runs t3.xlarge (system) and g5 (GPU) nodes.
#
# Steps:
#   1. Configure kubectl
#   2. Patch NodeClass files with subnet/SG/role IDs from Terraform outputs
#   3. kubectl apply NodePool + NodeClass files directly
#   4. Wait for at least one system node (t3.xlarge) to be Ready
#   5. Commit + push changes to main branch for ArgoCD to sync
bootstrap_custom_nodepools() {
    step "Phase 2b: Bootstrapping custom NodePools (t3.xlarge system, g5 GPU)"

    # --- Step 1: Configure kubectl ---
    cd "$TERRAFORM_DIR"
    EKS_CLUSTER_NAME=$(terraform output -raw eks_cluster_name 2>/dev/null)
    AWS_REGION=$(terraform output -raw region 2>/dev/null)

    log "Cluster: ${EKS_CLUSTER_NAME}  Region: ${AWS_REGION}"
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
    log "kubectl configured"

    # --- Step 2: Patch NodeClass files with Terraform outputs ---
    local subnet_ids sg_id role_name
    subnet_ids=$(terraform output -json private_subnet_ids 2>/dev/null)
    sg_id=$(terraform output -raw cluster_security_group_id 2>/dev/null)
    role_name=$(terraform output -raw node_role_name 2>/dev/null)

    if [[ -z "$subnet_ids" || -z "$sg_id" || -z "$role_name" ]]; then
        warn "Could not read Terraform outputs for NodeClass patching."
        warn "You may need to manually update k8s/nodepools/ files with correct subnet/SG/role IDs."
        cd "$REPO_DIR"
        return
    fi

    log "Subnet IDs: ${subnet_ids}"
    log "Security Group: ${sg_id}"
    log "Node Role: ${role_name}"

    # Convert JSON array to YAML subnet entries
    local subnet_yaml
    subnet_yaml=$(echo "$subnet_ids" | python3 -c "
import sys, json
ids = json.load(sys.stdin)
for sid in ids:
    print(f'    - id: {sid}')
")

    cd "$REPO_DIR"

    # Patch both NodeClass files
    for ncfile in k8s/nodepools/gpu-nodeclass.yaml k8s/nodepools/system-nodeclass.yaml; do
        if [[ ! -f "$ncfile" ]]; then
            warn "NodeClass file not found: $ncfile"
            continue
        fi

        log "Patching ${ncfile}..."

        # Replace role
        sed -i.bak "s/^  role: .*/  role: ${role_name}/" "$ncfile"

        # Replace subnetSelectorTerms block
        python3 -c "
import re, sys

with open('${ncfile}', 'r') as f:
    content = f.read()

# Replace subnet block
subnet_block = '''  subnetSelectorTerms:
${subnet_yaml}'''
content = re.sub(
    r'  subnetSelectorTerms:\n(    - id: [^\n]+\n)+',
    subnet_block + '\n',
    content
)

# Replace security group
content = re.sub(
    r'(  securityGroupSelectorTerms:\n    - id: )[^\n]+',
    r'\g<1>${sg_id}',
    content
)

with open('${ncfile}', 'w') as f:
    f.write(content)
"
        rm -f "${ncfile}.bak"
    done

    log "NodeClass files patched with new VPC IDs"

    # --- Step 3: kubectl apply NodePool + NodeClass directly ---
    echo ""
    log "Applying custom NodePool/NodeClass to cluster (before ArgoCD)..."

    # Apply NodeClasses first (NodePools reference them)
    kubectl apply -f k8s/nodepools/system-nodeclass.yaml
    kubectl apply -f k8s/nodepools/gpu-nodeclass.yaml
    # Apply NodePools
    kubectl apply -f k8s/nodepools/system-nodepool.yaml
    kubectl apply -f k8s/nodepools/gpu-nodepool.yaml

    log "Custom NodePools applied — Karpenter will provision t3.xlarge nodes"

    # --- Step 4: Wait for at least one system node (t3.xlarge) ---
    echo ""
    log "Waiting for system node (t3.xlarge) to be Ready..."
    local max_wait=300
    local interval=15
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        local system_nodes
        system_nodes=$(kubectl get nodes -l workload-type=system --no-headers 2>/dev/null | grep -c "Ready" || true)
        system_nodes="${system_nodes:-0}"

        if [[ "$system_nodes" -ge 1 ]]; then
            log "System node ready (t3.xlarge)"
            kubectl get nodes -o wide 2>/dev/null | head -5
            break
        fi

        echo -e "  ${DIM}[${waited}s] Waiting for t3.xlarge system node...${NC}"
        sleep "$interval"
        waited=$((waited + interval))
    done

    if [[ "$waited" -ge "$max_wait" ]]; then
        warn "System node not ready after ${max_wait}s — check NodePool/NodeClass status:"
        warn "  kubectl get nodepools,nodeclasses"
        warn "  kubectl describe nodeclass system-x86"
    fi

    # --- Step 4b: Neuter built-in "system" NodePool to prevent c6g.large provisioning ---
    # EKS Auto Mode REQUIRES node_pools=["system"] when nodeRoleArn is set (API rejects []).
    # The built-in pool provisions c6g.large Graviton instances we don't want.
    # Solution: patch limits to 0 CPU / 0 memory — pool exists (satisfies EKS) but can never
    # provision nodes. EKS does NOT revert this patch. Deleting the pool doesn't work because
    # EKS Auto Mode reconciler recreates it.
    if kubectl get nodepool system &>/dev/null; then
        log "Patching built-in 'system' NodePool limits to 0 — prevents c6g.large provisioning"
        kubectl patch nodepool system --type=merge -p '{"spec":{"limits":{"cpu":"0","memory":"0"}}}'
        # Also delete any existing NodeClaims from the built-in pool
        for nc in $(kubectl get nodeclaims -l karpenter.sh/nodepool=system -o name 2>/dev/null); do
            log "Deleting built-in NodeClaim: $nc"
            kubectl delete "$nc" --wait=false
        done
        log "Built-in pool neutered — only custom system-x86 (t3.xlarge) can provision nodes"
    fi

    # --- Step 5: Commit + push to main for ArgoCD ---
    if git diff --quiet k8s/nodepools/ 2>/dev/null; then
        log "NodeClass files unchanged — no commit needed"
    else
        log "Committing NodeClass updates..."
        git add k8s/nodepools/gpu-nodeclass.yaml k8s/nodepools/system-nodeclass.yaml

        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD)

        git commit -m "fix: update NodeClass subnet/SG/role IDs from Terraform outputs"

        if [[ "$current_branch" == "main" ]]; then
            git push
            log "Pushed NodeClass updates to main — ArgoCD will sync automatically"
        else
            # Push to current branch AND to main so ArgoCD picks up the changes
            git push
            log "Pushed to ${current_branch}"

            # Cherry-pick to main for ArgoCD
            local commit_hash
            commit_hash=$(git rev-parse HEAD)
            git stash --include-untracked 2>/dev/null || true
            git checkout main
            git pull --rebase origin main 2>/dev/null || true
            git cherry-pick "$commit_hash" --no-edit
            git push origin main
            git checkout "$current_branch"
            git stash pop 2>/dev/null || true
            log "Cherry-picked NodeClass fix to main — ArgoCD will sync automatically"
        fi
    fi
}

# ==============================================================================
# Phase 3: Cluster Setup (ArgoCD sync)
# ==============================================================================
setup_cluster() {
    step "Phase 3: Waiting for ArgoCD to sync workloads"

    cd "$REPO_DIR"

    # Wait for ArgoCD to sync
    log "ArgoCD deploys in wave order: Istio → Namespaces → Storage → Ollama → Gateway"
    log "System nodes (t3.xlarge) are already running — ArgoCD will schedule immediately"

    local max_wait=900
    local interval=20
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        local ollama_ns
        ollama_ns=$(kubectl get namespace ollama --no-headers 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$ollama_ns" -ge 1 ]]; then
            log "Ollama namespace created — ArgoCD waves progressing"
            break
        fi

        echo -e "  ${DIM}[${waited}s] Waiting for ArgoCD to create namespaces...${NC}"
        sleep "$interval"
        waited=$((waited + interval))
    done

    # Wait for Ollama deployment
    echo ""
    log "Waiting for Ollama deployment to be ready..."
    waited=0
    max_wait=600

    while [[ $waited -lt $max_wait ]]; do
        READY=$(kubectl get deployment ollama -n ollama \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        READY="${READY:-0}"

        if [[ "$READY" -ge 1 ]]; then
            log "Ollama is running (${READY} replica ready)"
            break
        fi

        echo -e "  ${DIM}[${waited}s] Waiting for Ollama (${READY}/1 ready — GPU node may still be provisioning)...${NC}"
        sleep "$interval"
        waited=$((waited + interval))
    done

    if [[ "$READY" -lt 1 ]]; then
        warn "Ollama not yet ready after ${max_wait}s — GPU node may still be initialising."
        warn "Check status: kubectl get pods -n ollama"
        warn "Check nodes:  kubectl get nodes"
    fi

    # Show ArgoCD status
    echo ""
    log "ArgoCD application status:"
    kubectl get applications -n argocd 2>/dev/null || true
}

# ==============================================================================
# Phase 3b: NLB Discovery + Final Terraform Apply
# ==============================================================================
# After ArgoCD deploys the Istio Gateway (Wave 5), an internal NLB is created
# by the AWS Load Balancer Controller. This step discovers the NLB, updates
# terraform.tfvars, and runs a final terraform apply to wire:
#   - API Gateway VPC Link → NLB
#   - CloudFront VPC Origin → NLB
# This is the final apply — after this, the full traffic path works:
#   Client → CloudFront → API Gateway → VPC Link → NLB → Istio → Ollama
wire_nlb_to_terraform() {
    step "Phase 3b: Discovering NLB and wiring API Gateway + CloudFront"

    # Wait for Istio Gateway service to get an external-ip (NLB DNS)
    log "Waiting for Istio Gateway NLB to be provisioned..."
    local max_wait=300
    local interval=15
    local waited=0
    local nlb_dns=""

    while [[ $waited -lt $max_wait ]]; do
        nlb_dns=$(kubectl get svc -n istio-ingress ollama-gateway-istio \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

        if [[ -n "$nlb_dns" ]]; then
            log "NLB DNS: ${nlb_dns}"
            break
        fi

        echo -e "  ${DIM}[${waited}s] Waiting for NLB to be provisioned...${NC}"
        sleep "$interval"
        waited=$((waited + interval))
    done

    if [[ -z "$nlb_dns" ]]; then
        warn "NLB not provisioned after ${max_wait}s — API Gateway wiring skipped."
        warn "Run manually: check 'kubectl get svc -n istio-ingress' then update terraform.tfvars"
        return
    fi

    # Discover NLB ARN via AWS CLI
    local region
    region=$(grep '^region' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"//;s/".*//')

    local nlb_arn
    nlb_arn=$(aws elbv2 describe-load-balancers --region "$region" \
        --query "LoadBalancers[?DNSName=='${nlb_dns}'].LoadBalancerArn" \
        --output text 2>/dev/null || echo "")

    if [[ -z "$nlb_arn" ]]; then
        warn "Could not find NLB ARN for DNS: ${nlb_dns}"
        warn "Update terraform.tfvars manually with nlb_arn and nlb_dns_name"
        return
    fi

    log "NLB ARN: ${nlb_arn}"

    # Update terraform.tfvars with NLB values
    cd "$TERRAFORM_DIR"
    sed -i.bak "s|^nlb_arn .*=.*|nlb_arn      = \"${nlb_arn}\"|" terraform.tfvars
    sed -i.bak "s|^nlb_dns_name .*=.*|nlb_dns_name = \"${nlb_dns}\"|" terraform.tfvars
    rm -f terraform.tfvars.bak

    log "terraform.tfvars updated with NLB values"

    # Final terraform apply — creates API Gateway VPC Link + CloudFront VPC Origin
    log "Running final Terraform apply (API Gateway VPC Link + CloudFront VPC Origin)..."
    log "Note: CloudFront VPC Origin creation takes ~7 minutes"
    terraform apply -auto-approve 2>&1 | tail -5

    if [[ $? -eq 0 ]]; then
        log "API Gateway and CloudFront VPC Origin wired successfully"
    else
        warn "Terraform apply had errors — check output above"
        warn "You may need to re-authenticate (aws sso login) and re-run: cd terraform && terraform apply -auto-approve"
    fi

    cd "$REPO_DIR"
}

# ==============================================================================
# Phase 4: Verification
# ==============================================================================
verify_deployment() {
    step "Phase 4: Verifying Stack A deployment"

    cd "$TERRAFORM_DIR"

    # Run air-gap verification
    log "Running air-gap verification..."
    echo ""
    "${SCRIPT_DIR}/verify-airgap.sh" || warn "Some air-gap checks failed — review output above"

    # Show connection info
    echo ""
    log "Retrieving connection details from Terraform outputs..."
    echo ""

    CLOUDFRONT_DOMAIN=$(terraform output -raw cloudfront_domain 2>/dev/null || echo "pending")
    API_KEY_ID=$(terraform output -raw api_key_id 2>/dev/null || echo "")
    MODEL=$(grep '^ollama_model' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"//;s/".*//')

    cd "$REPO_DIR"

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Stack A (Air-Gapped) Deployment Complete${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  CloudFront endpoint: https://${CLOUDFRONT_DOMAIN}"
    echo ""
    echo "  Get your API key:"
    if [[ -n "$API_KEY_ID" ]]; then
        echo "    aws apigateway get-api-key --api-key ${API_KEY_ID} --include-value --query value --output text"
    fi
    echo ""
    echo "  Test the endpoint:"
    echo "    API_KEY=\$(aws apigateway get-api-key --api-key ${API_KEY_ID} --include-value --query value --output text)"
    echo "    curl https://${CLOUDFRONT_DOMAIN}/v1/chat/completions \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -H \"x-api-key: \$API_KEY\" \\"
    echo "      -d '{\"model\": \"${MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
    echo ""
    echo "  Open WebUI (browser-based chat):"
    echo "    kubectl port-forward -n open-webui svc/open-webui 8080:8080"
    echo "    Open: http://localhost:8080"
    echo ""
    echo "  Grafana dashboards:"
    echo "    kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
    echo "    Open: http://localhost:3000"
    echo ""
    echo "  Switch model tiers:"
    echo "    ./switch-model.sh use 3   # Flagship (default)"
    echo "    ./switch-model.sh use 1   # Fallback (cheaper)"
    echo "    ./switch-model.sh use 2   # Coder (fast MoE)"
    echo ""
    echo "  Scale down (stop billing):"
    echo "    ./scripts/scale-down.sh"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Ollama on EKS — Stack A (Air-Gapped) Deployment${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Stack:  A — Fully Air-Gapped (Local LLM Only)"
echo "  Model:  qwen3.5:122b-a10b (Tier 3 Flagship)"
echo "  Region: ap-southeast-2 (Sydney)"
echo ""

check_prerequisites

if [[ "$SKIP_INFRA" == "false" ]]; then
    setup_backend
    deploy_infrastructure
    bootstrap_custom_nodepools
fi

setup_cluster
wire_nlb_to_terraform
verify_deployment
