#!/bin/bash
# Deploy — Fully Air-Gapped Ollama on EKS
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# End-to-end deployment of the air-gapped LLM inference platform:
#   Phase 1: Prerequisites — validate tools, AWS credentials, S3 backend
#   Phase 2: Infrastructure — terraform init + plan + apply
#   Phase 3: Cluster setup — configure kubectl, wait for ArgoCD waves
#   Phase 4: Verification — air-gap compliance checks
#
# This stack is fully air-gapped:
#   - All inference runs on local Ollama/Qwen (zero external API calls)
#   - No Bedrock VPC endpoints, no external model providers
#   - NetworkPolicies enforce air-gap on every namespace
#   - Prompts and source code never leave the AWS account
#
# Usage:
#   ./scripts/deploy.sh                  # Full deployment
#   ./scripts/deploy.sh --auto-approve   # No-touch — skip confirmation prompt
#   ./scripts/deploy.sh --plan-only      # Terraform plan only (no apply)
#   ./scripts/deploy.sh --skip-infra     # Skip Terraform (cluster already exists)
#
# Prerequisites:
#   - AWS CLI configured (aws sts get-caller-identity works)
#   - Terraform >= 1.0 installed
#   - kubectl installed
#   - helm installed

set -euo pipefail

# Disable AWS CLI pager — prevents `less` from opening mid-script
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

# Parse arguments
PLAN_ONLY=false
SKIP_INFRA=false
AUTO_APPROVE=false
for arg in "$@"; do
    case "$arg" in
        --plan-only)     PLAN_ONLY=true ;;
        --skip-infra)    SKIP_INFRA=true ;;
        --auto-approve)  AUTO_APPROVE=true ;;
        --help|-h)
            echo "Usage: $0 [--auto-approve] [--plan-only] [--skip-infra]"
            echo "  --auto-approve  Skip confirmation prompt (for CI/CD)"
            echo "  --plan-only     Run terraform plan without applying"
            echo "  --skip-infra    Skip Terraform (cluster already deployed)"
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

# Helper: portable sed -i (macOS BSD vs Linux GNU)
sedi() {
    if sed --version &>/dev/null 2>&1; then
        # GNU sed
        sed -i "$@"
    else
        # BSD sed (macOS)
        sed -i '' "$@"
    fi
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
                terraform) version=$(terraform version 2>/dev/null | head -1) ;;
                kubectl)   version=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1) ;;
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

    # Verify air-gapped config
    echo ""
    log "Verifying air-gapped configuration..."

    REGION=$(grep '^region' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"//;s/".*//')
    BEDROCK=$(grep '^enable_bedrock' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *//' || echo "false")
    MODEL=$(grep '^ollama_model' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"//;s/".*//')

    log "Region:         ${REGION}"
    log "Bedrock:        ${BEDROCK}"
    log "Default model:  ${MODEL}"

    if [[ "$BEDROCK" == "true" ]]; then
        error "enable_bedrock=true in terraform.tfvars — not supported in this repo."
        error "Set enable_bedrock=false (air-gapped). For hybrid/Bedrock, use the Hybrid-LLM repo."
        exit 1
    fi

    # Check GPU Service Quotas (required for Karpenter to provision g5 instances)
    echo ""
    log "Checking GPU Service Quotas..."
    local spot_quota on_demand_quota
    spot_quota=$(aws service-quotas get-service-quota --service-code ec2 \
        --quota-code L-3819A6DF --region "$REGION" \
        --query 'Quota.Value' --output text 2>/dev/null || echo "0")
    on_demand_quota=$(aws service-quotas get-service-quota --service-code ec2 \
        --quota-code L-DB2E81BA --region "$REGION" \
        --query 'Quota.Value' --output text 2>/dev/null || echo "0")

    log "GPU Spot quota (G/VT):      ${spot_quota} vCPUs"
    log "GPU On-Demand quota (G/VT): ${on_demand_quota} vCPUs"

    # Use shell arithmetic (no bc dependency)
    local spot_int on_demand_int
    spot_int=${spot_quota%.*}
    on_demand_int=${on_demand_quota%.*}
    spot_int=${spot_int:-0}
    on_demand_int=${on_demand_int:-0}

    if [[ "$spot_int" -lt 4 ]] && [[ "$on_demand_int" -lt 4 ]]; then
        warn "GPU quotas are 0 or very low — Karpenter will fail to provision GPU nodes."
        warn "Request increases: https://console.aws.amazon.com/servicequotas"
        warn "  L-3819A6DF (G/VT Spot): minimum 4 vCPUs for g5.xlarge"
        warn "  L-DB2E81BA (G/VT On-Demand): minimum 4 vCPUs for g5.xlarge"
        warn "Continuing deploy — system nodes will work, but GPU workloads will not start."
    fi

    # Reset stale NLB/CloudFront values for fresh deploys
    # Phase 2 and Phase 3b will discover and populate the correct values
    echo ""
    log "Resetting NLB/CloudFront values for clean deployment..."
    sedi 's|^nlb_arn .*=.*|nlb_arn      = ""|' "$TERRAFORM_DIR/terraform.tfvars"
    sedi 's|^nlb_dns_name .*=.*|nlb_dns_name = ""|' "$TERRAFORM_DIR/terraform.tfvars"
    sedi 's|^cloudfront_domain = .*|cloudfront_domain = ""|' "$TERRAFORM_DIR/terraform.tfvars"
    log "Stale values cleared — will be auto-discovered during deployment"

    log "Air-gapped configuration verified"
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
        sedi "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g" "$TERRAFORM_DIR/backend.tf"
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
    if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
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
        terraform init -migrate-state -input=false 2>&1 || {
            warn "Init with -migrate-state failed. Retrying standard init..."
            terraform init -input=false -reconfigure
        }
    else
        terraform init -input=false 2>&1 || {
            warn "Init failed. Retrying with -reconfigure..."
            terraform init -input=false -reconfigure
        }
    fi

    # Terraform plan
    echo ""
    log "Running terraform plan..."
    terraform plan -out=tfplan -input=false

    if [[ "$PLAN_ONLY" == "true" ]]; then
        log "Plan complete. Run without --plan-only to apply."
        cd "$REPO_DIR"
        exit 0
    fi

    # Confirm before apply (skipped with --auto-approve)
    if [[ "$AUTO_APPROVE" != "true" ]]; then
        echo ""
        echo -e "${YELLOW}${BOLD}  Review the plan above.${NC}"
        read -r -p "  Apply this plan? [y/N] " confirm
        if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
            echo ""
            echo "  Aborted. Plan saved to terraform/tfplan."
            echo "  To apply later: cd terraform && terraform apply tfplan"
            cd "$REPO_DIR"
            exit 0
        fi
    fi

    # Terraform apply
    # Retry logic: EKS API server may not be fully stable when Helm charts
    # install (connection reset errors on ClusterRole creation). The cluster
    # needs ~1-2 min after creation for the API server to stabilize.
    # Retry up to 3 times with a 60s wait between attempts.
    echo ""
    local apply_attempt=0
    local apply_max=3
    while [[ $apply_attempt -lt $apply_max ]]; do
        apply_attempt=$((apply_attempt + 1))
        log "Applying Terraform plan (attempt ${apply_attempt}/${apply_max})..."

        if [[ -f tfplan ]]; then
            if terraform apply -input=false -parallelism=30 tfplan 2>&1 | tee /tmp/tf-apply.log; then
                rm -f tfplan
                break
            fi
        else
            # Retry without saved plan (plan was consumed by first attempt)
            if terraform apply -auto-approve -input=false -parallelism=30 2>&1 | tee /tmp/tf-apply.log; then
                break
            fi
        fi

        rm -f tfplan
        if [[ $apply_attempt -lt $apply_max ]]; then
            warn "Terraform apply failed (attempt ${apply_attempt}/${apply_max})"

            # Self-healing: clean up orphaned Helm releases that block retries.
            # When Terraform fails mid-apply, Helm releases may exist in the cluster
            # but not in Terraform state. The next "helm install" fails with
            # "cannot re-use a name that is still in use".
            log "Cleaning up orphaned Helm releases before retry..."
            if kubectl cluster-info &>/dev/null; then
                for release in kube-prometheus-stack dcgm-exporter; do
                    if helm status "$release" -n monitoring &>/dev/null; then
                        if ! terraform state list 2>/dev/null | grep -q "helm_release.*${release//-/_}"; then
                            warn "  Removing orphaned Helm release: ${release}"
                            helm uninstall "$release" -n monitoring --wait --timeout 120s 2>/dev/null || true
                        fi
                    fi
                done
            fi

            log "Retrying in 60s..."
            sleep 60
        else
            error "Terraform apply failed after ${apply_max} attempts"
            error "Check /tmp/tf-apply.log for details"
            cd "$REPO_DIR"
            return 1
        fi
    done

    log "Terraform apply complete"

    # Save CloudFront domain to tfvars (for reference / future applies)
    # No Phase 2 re-apply needed — Cognito, portal, and login all reference
    # module.cdn_waf.cloudfront_domain directly (resolved in the same apply).
    echo ""
    CLOUDFRONT_DOMAIN=$(terraform output -raw cloudfront_domain 2>/dev/null || echo "")
    if [[ -n "$CLOUDFRONT_DOMAIN" ]]; then
        log "CloudFront domain: ${CLOUDFRONT_DOMAIN}"
        sedi "s|^cloudfront_domain = .*|cloudfront_domain = \"${CLOUDFRONT_DOMAIN}\"|" terraform.tfvars
    else
        warn "Could not get CloudFront domain from outputs"
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
        sedi "s/^  role: .*/  role: ${role_name}/" "$ncfile"

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
# Phase 2c: ArgoCD Git Credentials (private repo access)
# ==============================================================================
setup_argocd_repo_credentials() {
    step "Phase 2c: Configuring ArgoCD Git credentials"

    # Check if ArgoCD already has a repo secret for this repo
    local existing
    existing=$(kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repository \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$existing" ]]; then
        log "ArgoCD repo credential already exists: ${existing}"
        return
    fi

    # Try to get GitHub token from gh CLI (most reliable for zero-touch)
    local gh_token=""
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        gh_token=$(gh auth token 2>/dev/null || echo "")
    fi

    if [[ -z "$gh_token" ]]; then
        # Fallback: check GITHUB_TOKEN env var
        gh_token="${GITHUB_TOKEN:-}"
    fi

    if [[ -z "$gh_token" ]]; then
        warn "No GitHub token available for ArgoCD."
        warn "ArgoCD cannot sync from private repos without credentials."
        warn "Fix: run 'gh auth login' or set GITHUB_TOKEN, then re-run deploy."
        warn "Or make the repo public."
        return
    fi

    local repo_url
    repo_url=$(grep '^git_repo_url' "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"//;s/".*//')

    log "Creating ArgoCD repo credential for: ${repo_url}"
    kubectl create secret generic argocd-repo-creds \
        --namespace argocd \
        --from-literal=type=git \
        --from-literal=url="$repo_url" \
        --from-literal=username=shanaka-versent \
        --from-literal=password="$gh_token" \
        --dry-run=client -o yaml \
        | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
        | kubectl apply -f - 2>&1

    log "ArgoCD repo credential created — ArgoCD will auto-detect and sync"
}

# ==============================================================================
# Phase 2d: Model Snapshot Validation
# ==============================================================================
# The Ollama deployment uses an EBS snapshot with pre-loaded models for fast
# cold starts (~3 min vs ~20 min pulling from internet). If the snapshot doesn't
# exist (first deploy or snapshot was deleted), we patch the deployment to use
# a blank volume and let the model-loader job pull the model at runtime.
handle_model_snapshot() {
    step "Phase 2d: Validating model EBS snapshot"

    # Read snapshot ID from the volume-snapshot manifest
    local snapshot_file="${REPO_DIR}/k8s/ollama/volume-snapshot.yaml"
    local snapshot_id=""
    if [[ -f "$snapshot_file" ]]; then
        snapshot_id=$(grep 'snapshotHandle:' "$snapshot_file" | awk '{print $2}' | head -1)
    fi

    if [[ -z "$snapshot_id" ]]; then
        warn "No snapshot ID found in volume-snapshot.yaml"
        warn "Model-loader will pull the model from internet (~15-25 min on first start)"
        return
    fi

    log "Checking EBS snapshot: ${snapshot_id}"
    local snap_state
    snap_state=$(aws ec2 describe-snapshots --snapshot-ids "$snapshot_id" \
        --region "$REGION" --query 'Snapshots[0].State' --output text 2>/dev/null || echo "not-found")

    if [[ "$snap_state" == "completed" ]]; then
        log "Snapshot ${snapshot_id} exists and is ready — fast cold start enabled"
        return
    fi

    warn "Snapshot ${snapshot_id} not found (state: ${snap_state})"
    warn "Removing dataSource from deployment YAML — model-loader will pull from internet"
    warn "To restore fast cold starts, run: ./scripts/create-model-snapshot.sh"

    # Remove dataSource block from the deployment YAML in git
    # ArgoCD selfHeal=true reverts kubectl patches, so we must change the source
    local deploy_file="${REPO_DIR}/k8s/ollama/deployment.yaml"
    if grep -q 'dataSource:' "$deploy_file" 2>/dev/null; then
        # Remove the dataSource block (3-4 lines: dataSource:, name:, kind:, apiGroup:)
        python3 -c "
import re
with open('${deploy_file}', 'r') as f:
    content = f.read()
# Remove dataSource block (indented under volumeClaimTemplate spec)
content = re.sub(
    r'\n\s+dataSource:\n\s+name: ollama-models-snapshot\n\s+kind: VolumeSnapshot\n\s+apiGroup: snapshot\.storage\.k8s\.io',
    '',
    content
)
with open('${deploy_file}', 'w') as f:
    f.write(content)
"
        log "dataSource removed from ${deploy_file}"

        # Commit and push so ArgoCD picks up the change
        cd "$REPO_DIR"
        git add "$deploy_file"
        if ! git diff --cached --quiet; then
            git commit -m "fix: remove snapshot dataSource — not available on fresh deploy"
            git push origin main 2>/dev/null || warn "Could not push — ArgoCD will sync on next push"
        fi
        cd "$TERRAFORM_DIR"
    else
        log "dataSource already removed from deployment YAML"
    fi

    # Also remove the VolumeSnapshot/Content/Class if they reference a missing snapshot
    kubectl delete volumesnapshot ollama-models-snapshot -n ollama 2>/dev/null || true
    kubectl delete volumesnapshotcontent ollama-models-snapshot-content 2>/dev/null || true

    log "Snapshot cleanup complete — model-loader will pull from internet"
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
        local ready
        ready=$(kubectl get deployment ollama -n ollama \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        ready="${ready:-0}"

        if [[ "$ready" -ge 1 ]]; then
            log "Ollama is running (${ready} replica ready)"
            break
        fi

        echo -e "  ${DIM}[${waited}s] Waiting for Ollama (${ready}/1 ready — GPU node may still be provisioning)...${NC}"
        sleep "$interval"
        waited=$((waited + interval))
    done

    if [[ "${ready:-0}" -lt 1 ]]; then
        warn "Ollama not yet ready after ${max_wait}s — GPU node may still be initialising."
        warn "Check status: kubectl get pods -n ollama"
        warn "Check nodes:  kubectl get nodes"
    fi

    echo ""
    log "ArgoCD application status:"
    kubectl get applications -n argocd 2>/dev/null || true

    # --- Start Ollama + preload model ---
    # KEDA starts with 0 replicas. We need to pause KEDA, scale up Ollama,
    # wait for the model to load, then unpause KEDA (45-min idle window starts).
    echo ""
    log "Starting Ollama and preloading model..."

    # Pause KEDA to prevent it from killing the pod before model loads
    kubectl annotate scaledobject ollama-autoscaler -n ollama \
        autoscaling.keda.sh/paused="true" --overwrite 2>/dev/null || true

    # Scale Ollama to 1
    kubectl scale deployment ollama -n ollama --replicas=1 2>/dev/null || true

    # Wait for Ollama pod to be ready (startup probe: model loading ~2-5 min)
    log "Waiting for Ollama to be ready (GPU provisioning + model loading)..."
    local ollama_ready=0
    local ollama_wait=0
    local ollama_max=600
    while [[ $ollama_wait -lt $ollama_max ]]; do
        ollama_ready=$(kubectl get deployment ollama -n ollama \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        ollama_ready="${ollama_ready:-0}"

        if [[ "$ollama_ready" -ge 1 ]]; then
            log "Ollama is ready"
            break
        fi

        echo -e "  ${DIM}[${ollama_wait}s] Waiting for Ollama (GPU node + model loading)...${NC}"
        sleep 20
        ollama_wait=$((ollama_wait + 20))
    done

    if [[ "$ollama_ready" -ge 1 ]]; then
        # Preload model — triggers model-loader job or pulls directly
        log "Preloading model: ${MODEL}..."
        kubectl exec -n open-webui deploy/open-webui -- \
            curl -sf --max-time 30 \
            "http://ollama.ollama.svc.cluster.local:11434/api/tags" 2>/dev/null | head -1 || true

        # Unpause KEDA — 45-min idle window starts now
        kubectl annotate scaledobject ollama-autoscaler -n ollama \
            autoscaling.keda.sh/paused- --overwrite 2>/dev/null || true
        log "KEDA unpaused — 45-min idle timer started"
    else
        warn "Ollama not ready after ${ollama_max}s — check GPU node provisioning"
        warn "Manual start: kubectl scale deployment ollama -n ollama --replicas=1"
        # Unpause KEDA even on failure — never leave it paused
        kubectl annotate scaledobject ollama-autoscaler -n ollama \
            autoscaling.keda.sh/paused- --overwrite 2>/dev/null || true
    fi
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

    # Wait for NLB to be fully active before terraform apply.
    # CloudFront VPC Origin creation fails if NLB is still provisioning.
    log "Waiting for NLB to become active..."
    local nlb_wait=0
    local nlb_max_wait=180
    while [[ $nlb_wait -lt $nlb_max_wait ]]; do
        local nlb_state
        nlb_state=$(aws elbv2 describe-load-balancers --region "$region" \
            --load-balancer-arns "$nlb_arn" \
            --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "unknown")
        if [[ "$nlb_state" == "active" ]]; then
            log "NLB is active"
            break
        fi
        echo -e "  ${DIM}[${nlb_wait}s] NLB state: ${nlb_state} — waiting...${NC}"
        sleep 15
        nlb_wait=$((nlb_wait + 15))
    done

    cd "$TERRAFORM_DIR"
    sedi "s|^nlb_arn .*=.*|nlb_arn      = \"${nlb_arn}\"|" terraform.tfvars
    sedi "s|^nlb_dns_name .*=.*|nlb_dns_name = \"${nlb_dns}\"|" terraform.tfvars

    log "terraform.tfvars updated with NLB values"

    # Final terraform apply — creates API Gateway VPC Link + CloudFront VPC Origin
    log "Running final Terraform apply (API Gateway VPC Link + CloudFront VPC Origin)..."
    log "Note: CloudFront VPC Origin creation takes ~7 minutes"
    if ! terraform apply -auto-approve -input=false 2>&1 | tee /tmp/tf-final.log; then
        error "Final terraform apply failed — check /tmp/tf-final.log"
        cd "$REPO_DIR"
        return 1
    fi
    log "CloudFront VPC Origin wired successfully"

    # --- Warm up CloudFront VPC Origin until consistently fast ---
    # VPC Origins have a cold start (10-30s on first requests while AWS
    # establishes the private connection). We keep hitting the endpoint
    # until we get 3 consecutive fast responses (<5s), ensuring the user
    # sees a fast page load immediately after deploy completes.
    local cf_domain
    cf_domain=$(terraform output -raw cloudfront_domain 2>/dev/null || echo "")
    if [[ -n "$cf_domain" ]]; then
        log "Warming up CloudFront VPC Origin (this may take 1-2 min)..."

        # Phase 1: Blast 5 parallel requests to open the connection
        for i in 1 2 3 4 5; do
            curl -s -o /dev/null --max-time 35 "https://${cf_domain}/api/config" 2>/dev/null &
        done
        wait

        # Phase 2: Keep hitting until 3 consecutive fast responses (<5s)
        local consecutive_fast=0
        local warmup_attempt=0
        local warmup_max=20
        while [[ $consecutive_fast -lt 3 ]] && [[ $warmup_attempt -lt $warmup_max ]]; do
            warmup_attempt=$((warmup_attempt + 1))
            local warmup_time
            warmup_time=$(curl -s -o /dev/null -w "%{time_total}" --max-time 35 "https://${cf_domain}/api/config" 2>/dev/null || echo "99")
            local warmup_code
            warmup_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${cf_domain}/api/config" 2>/dev/null || echo "000")

            # Check if response was fast (under 5 seconds)
            local is_fast
            is_fast=$(python3 -c "print('yes' if float('${warmup_time}') < 5.0 else 'no')" 2>/dev/null || echo "no")

            if [[ "$is_fast" == "yes" ]] && [[ "$warmup_code" == "200" ]]; then
                consecutive_fast=$((consecutive_fast + 1))
                echo -e "  ${DIM}[${warmup_attempt}] ${warmup_time}s — fast (${consecutive_fast}/3)${NC}"
            else
                consecutive_fast=0
                echo -e "  ${DIM}[${warmup_attempt}] ${warmup_time}s — warming up...${NC}"
            fi
        done

        if [[ $consecutive_fast -ge 3 ]]; then
            log "VPC Origin warm — 3 consecutive fast responses confirmed"
        else
            warn "VPC Origin may still be cold after ${warmup_max} attempts"
        fi

        # Phase 3: Pre-warm key pages (login, static assets)
        log "Pre-warming key pages..."
        for path in "/auth/login.html" "/" "/api/config" "/manifest.json"; do
            curl -s -o /dev/null --max-time 10 "https://${cf_domain}${path}" 2>/dev/null &
        done
        wait
        log "Platform ready at: https://${cf_domain}"
    fi

    cd "$REPO_DIR"
}

# ==============================================================================
# Phase 3c: Setup Grafana dashboards
# ==============================================================================
setup_grafana_dashboards() {
    step "Phase 3c: Setting up Grafana dashboards"

    # Check if AMG is enabled (enable_managed_grafana in tfvars)
    local amg_enabled
    amg_enabled=$(grep '^enable_managed_grafana' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null | sed 's/.*= *//' | tr -d ' ' || echo "false")

    if [[ "$amg_enabled" == "true" ]]; then
        # AMG mode — run setup-amg.sh
        local workspace_name
        workspace_name=$(cd "$TERRAFORM_DIR" && terraform output -raw managed_grafana_workspace_name 2>/dev/null || echo "ollama-grafana")

        local amg_status
        amg_status=$(aws grafana list-workspaces --region "$REGION" \
            --query "workspaces[?name==\`${workspace_name}\`].status" --output text 2>/dev/null || echo "")

        if [[ "$amg_status" == "ACTIVE" ]] && [[ -x "${SCRIPT_DIR}/setup-amg.sh" ]]; then
            log "Running setup-amg.sh (AMG data sources + dashboards)..."
            "${SCRIPT_DIR}/setup-amg.sh" || warn "AMG setup had errors — run manually: ./scripts/setup-amg.sh"
        else
            warn "AMG workspace not ACTIVE (status: ${amg_status:-not found}) — skipping"
        fi
    else
        # In-cluster Grafana mode — dashboards auto-discovered via sidecar
        log "Using in-cluster Grafana (AMG disabled)"
        log "Dashboards auto-discovered via ConfigMap sidecar"
        log "Access: kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
        log "Login: admin / ollama-grafana-admin"
    fi
}

# ==============================================================================
# Phase 4: Verification
# ==============================================================================
verify_deployment() {
    step "Phase 4: Verifying deployment"

    cd "$TERRAFORM_DIR"

    # Run air-gap verification
    log "Running air-gap verification..."
    echo ""
    "${SCRIPT_DIR}/verify-airgap.sh" || warn "Some air-gap checks failed — review output above"

    # Show connection info
    echo ""
    log "Retrieving connection details..."
    echo ""

    CLOUDFRONT_DOMAIN=$(terraform output -raw cloudfront_domain 2>/dev/null || echo "pending")
    API_KEY_ID=$(terraform output -raw api_key_id 2>/dev/null || echo "")
    GRAFANA_URL=$(terraform output -raw managed_grafana_url 2>/dev/null || echo "pending")
    local region
    region=$(terraform output -raw region 2>/dev/null || echo "$REGION")

    cd "$REPO_DIR"

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Air-Gapped Deployment Complete${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Region:              ${region}"
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
    echo "    https://${CLOUDFRONT_DOMAIN}"
    echo ""
    echo "  Grafana dashboards (via IAM Identity Center SSO):"
    echo "    ${GRAFANA_URL}"
    echo ""
    echo "  Switch local model tiers:"
    echo "    ./switch-model.sh use 3   # Flagship (best local quality)"
    echo "    ./switch-model.sh use 1   # Fallback (cheaper)"
    echo "    ./switch-model.sh use 2   # Coder (fast MoE)"
    echo ""
    echo "  Scale down (stop GPU billing):"
    echo "    ./scripts/scale-down.sh"
    echo ""
    echo -e "${YELLOW}  ACTION REQUIRED — Confirm SNS email subscriptions:${NC}"
    echo "    Check your inbox for 2 SNS confirmation emails:"
    echo "    1. Alert notifications (GPU alerts, spot interruptions)"
    echo "    2. Signup notifications (new user requests)"
    echo "    Click 'Confirm subscription' in each email to activate."
    echo ""

    # --- Final warmup — ensure platform is ready to use RIGHT NOW ---
    # The VPC Origin can go cold during the verification phase (~2-3 min).
    # This final blast ensures the user hits a fast page load immediately.
    if [[ -n "$CLOUDFRONT_DOMAIN" ]]; then
        log "Final warmup — ensuring platform is ready to use..."

        # Blast 5 parallel to re-open the connection
        for i in 1 2 3 4 5; do
            curl -s -o /dev/null --max-time 35 "https://${CLOUDFRONT_DOMAIN}/api/config" 2>/dev/null &
        done
        wait

        # Verify 3 consecutive fast responses
        local final_fast=0
        local final_attempt=0
        while [[ $final_fast -lt 3 ]] && [[ $final_attempt -lt 15 ]]; do
            final_attempt=$((final_attempt + 1))
            local ft
            ft=$(curl -s -o /dev/null -w "%{time_total}" --max-time 15 "https://${CLOUDFRONT_DOMAIN}/api/config" 2>/dev/null || echo "99")
            local is_fast
            is_fast=$(python3 -c "print('yes' if float('${ft}') < 5.0 else 'no')" 2>/dev/null || echo "no")
            if [[ "$is_fast" == "yes" ]]; then
                final_fast=$((final_fast + 1))
            else
                final_fast=0
            fi
        done

        # Pre-warm key pages
        for path in "/auth/login.html" "/" "/manifest.json"; do
            curl -s -o /dev/null --max-time 10 "https://${CLOUDFRONT_DOMAIN}${path}" 2>/dev/null &
        done
        wait

        if [[ $final_fast -ge 3 ]]; then
            log "Platform is warm and ready to use: https://${CLOUDFRONT_DOMAIN}"
        else
            warn "Platform may be slow on first load — VPC Origin still warming"
        fi
    fi
}

# ==============================================================================
# Main
# ==============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Ollama on EKS — Air-Gapped Deployment${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Stack:  Air-Gapped (Local LLM Only)"
echo "  Model:  qwen3.5:122b-a10b (Tier 3 Flagship)"
echo "  Region: ap-southeast-2 (Sydney)"
echo ""

check_prerequisites

if [[ "$SKIP_INFRA" == "false" ]]; then
    setup_backend
    deploy_infrastructure
    bootstrap_custom_nodepools
fi

setup_argocd_repo_credentials
handle_model_snapshot
setup_cluster
wire_nlb_to_terraform
setup_grafana_dashboards
verify_deployment
