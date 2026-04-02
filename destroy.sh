#!/bin/bash
# Destroy Ollama on EKS — Wrapper Script
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Thin wrapper around scripts/delete-stack.sh which handles the full
# 5-phase ordered teardown: GPU scale-down, CloudFront VPC Origins,
# ArgoCD + NLB cleanup, Terraform destroy (with retries), and
# orphaned resource verification.
#
# Usage:
#   ./destroy.sh                 # Interactive teardown with confirmation
#   ./destroy.sh --force         # Skip confirmation prompt
#   ./destroy.sh --skip-terraform # K8s + AWS cleanup only (no terraform destroy)
#   ./destroy.sh --help          # Show usage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/scripts/delete-stack.sh" "$@"
