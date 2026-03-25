#!/usr/bin/env bash
# upgrade-eks-version.sh — Sequential EKS K8s version upgrade
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# EKS only allows +1 minor version upgrades at a time.
# This script steps through each intermediate version automatically.
#
# Usage: ./scripts/upgrade-eks-version.sh [TARGET_VERSION] [TFVARS_FILE]
#   e.g.: ./scripts/upgrade-eks-version.sh 1.34
#
# Default: upgrades to 1.34 using terraform.tfvars

set -euo pipefail

TARGET_VERSION="${1:-1.34}"
TFVARS_FILE="${2:-terraform.tfvars}"
CLUSTER_NAME="${3:-eks-ollama-dev}"
REGION="ap-southeast-2"
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

echo "=== EKS Kubernetes Version Upgrade ==="
echo "Target version:  $TARGET_VERSION"
echo "Tfvars file:     $TFVARS_FILE"
echo "Cluster:         $CLUSTER_NAME"
echo ""

# Get current cluster version
CURRENT_VERSION=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query 'cluster.version' \
  --output text 2>/dev/null)

if [ -z "$CURRENT_VERSION" ]; then
  echo "ERROR: Could not get current cluster version. Check AWS credentials and cluster name."
  exit 1
fi

echo "Current version: $CURRENT_VERSION"

# Parse minor versions (e.g., "1.31" -> 31)
current_minor=$(echo "$CURRENT_VERSION" | cut -d. -f2)
target_minor=$(echo "$TARGET_VERSION" | cut -d. -f2)

if [ "$current_minor" -ge "$target_minor" ]; then
  echo "Cluster is already on $CURRENT_VERSION (>= $TARGET_VERSION). Nothing to do."
  exit 0
fi

# Calculate upgrade steps
steps=$((target_minor - current_minor))
echo "Upgrade path: $steps step(s) required"
echo ""

# Step through each version
for ((v = current_minor + 1; v <= target_minor; v++)); do
  step_version="1.$v"
  step_num=$((v - current_minor))

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Step $step_num/$steps: Upgrading to K8s $step_version"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Temporarily set the version in tfvars for this step
  cd "$TF_DIR"
  sed -i.bak "s/kubernetes_version = \"1\.[0-9]*\"/kubernetes_version = \"$step_version\"/" "$TFVARS_FILE"

  echo "Running terraform apply for K8s $step_version..."
  terraform apply -auto-approve \
    -target=module.eks 2>&1 | tail -5

  echo ""
  echo "Waiting for cluster upgrade to complete..."

  # Poll until cluster is ACTIVE (upgrade can take 10-25 min)
  while true; do
    status=$(aws eks describe-cluster \
      --name "$CLUSTER_NAME" \
      --region "$REGION" \
      --query 'cluster.status' \
      --output text 2>/dev/null)
    version=$(aws eks describe-cluster \
      --name "$CLUSTER_NAME" \
      --region "$REGION" \
      --query 'cluster.version' \
      --output text 2>/dev/null)

    if [ "$status" = "ACTIVE" ] && [ "$version" = "$step_version" ]; then
      echo "Cluster is ACTIVE on K8s $step_version"
      break
    fi

    echo "  Status: $status, Version: $version — waiting 30s..."
    sleep 30
  done

  # Clean up backup
  rm -f "$TFVARS_FILE.bak"
  echo ""
done

# Restore the final target version in tfvars (should already be correct)
cd "$TF_DIR"
sed -i.bak "s/kubernetes_version = \"1\.[0-9]*\"/kubernetes_version = \"$TARGET_VERSION\"/" "$TFVARS_FILE"
rm -f "$TFVARS_FILE.bak"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Upgrade complete! Cluster is now on K8s $TARGET_VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Post-upgrade verification:"
echo "  kubectl version"
echo "  kubectl get nodes -o wide"
echo "  kubectl get pods -A"
echo "  ./scripts/test-ollama-stack.sh"
