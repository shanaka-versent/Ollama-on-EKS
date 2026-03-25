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
# Phase 2b: Patch NodeClass files with Terraform outputs
# ==============================================================================
# EKS Auto Mode NodeClass requires explicit subnet/SG IDs (tag-based discovery
# not supported). After terraform apply creates a new VPC, the IDs change.
# This step reads the new IDs from Terraform outputs and patches the K8s YAML
# files, then commits + pushes so ArgoCD picks up the correct values.
patch_nodeclass_files() {
    step "Phase 2b: Patching NodeClass files with new VPC IDs"

    cd "$TERRAFORM_DIR"

    # Read Terraform outputs
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

        # Replace subnetSelectorTerms block (everything between subnetSelectorTerms: and securityGroupSelectorTerms:)
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

    log "NodeClass files patched"

    # Commit and push so ArgoCD picks up the changes
    if git diff --quiet k8s/nodepools/ 2>/dev/null; then
        log "NodeClass files unchanged — no commit needed"
    else
        log "Committing NodeClass updates..."
        git add k8s/nodepools/gpu-nodeclass.yaml k8s/nodepools/system-nodeclass.yaml
        git commit -m "fix: update NodeClass subnet/SG/role IDs from Terraform outputs"
        git push
        log "Pushed NodeClass updates to Git — ArgoCD will sync automatically"
    fi
}

# ==============================================================================
# Phase 3: Cluster Setup
# ==============================================================================
setup_cluster() {
    step "Phase 3: Configuring cluster access"

    cd "$TERRAFORM_DIR"

    # Configure kubectl
    EKS_CLUSTER_NAME=$(terraform output -raw eks_cluster_name 2>/dev/null)
    AWS_REGION=$(terraform output -raw region 2>/dev/null)

    log "Cluster: ${EKS_CLUSTER_NAME}  Region: ${AWS_REGION}"
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
    log "kubectl configured"

    cd "$REPO_DIR"

    # Wait for ArgoCD to sync
    echo ""
    log "Waiting for ArgoCD to sync workloads (this may take 10-15 minutes)..."
    log "ArgoCD deploys in wave order: Istio → Namespaces → Storage → Ollama → Gateway"

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
    patch_nodeclass_files
fi

setup_cluster
verify_deployment
