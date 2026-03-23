#!/usr/bin/env bash
# create-model-snapshot.sh — Create EBS snapshot with pre-loaded Ollama models
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Launches a temporary g5.xlarge, pulls all 3 model tiers onto a 200GB gp3
# data volume, snapshots the volume, and terminates the instance.
#
# Prerequisites:
#   - AWS CLI configured with appropriate IAM permissions
#   - A VPC with a public subnet (for pulling models)
#   - A security group that allows outbound HTTPS
#
# Usage:
#   ./scripts/create-model-snapshot.sh
#
# Output:
#   Snapshot ID to use in k8s/nodepools/gpu-ec2nodeclass.yaml

set -euo pipefail

REGION="ap-southeast-2"
INSTANCE_TYPE="g5.xlarge"
VOLUME_SIZE=200
VOLUME_TYPE="gp3"
VOLUME_IOPS=6000
VOLUME_THROUGHPUT=400
KEY_NAME="${KEY_NAME:-}"  # Optional — set if you need SSH access for debugging

# Models to pre-load (all 3 tiers)
MODELS=(
  "qwen3.5:27b"
  "qwen3-coder:30b-a3b"
  "qwen3.5:122b-a10b"
)

echo "=== Ollama Model Snapshot Creator ==="
echo "Region: ${REGION}"
echo "Instance: ${INSTANCE_TYPE}"
echo "Volume: ${VOLUME_SIZE}GB ${VOLUME_TYPE} (${VOLUME_IOPS} IOPS, ${VOLUME_THROUGHPUT} MB/s)"
echo "Models: ${MODELS[*]}"
echo ""

# --- Step 1: Get latest AL2023 AMI ---
echo "[1/7] Finding latest AL2023 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --region "${REGION}" \
  --owners amazon \
  --filters \
    "Name=name,Values=al2023-ami-2023.*-x86_64" \
    "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)
echo "  AMI: ${AMI_ID}"

# --- Step 2: Find subnet and security group ---
echo "[2/7] Finding default VPC resources..."
VPC_ID=$(aws ec2 describe-vpcs \
  --region "${REGION}" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
  --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[?MapPublicIpOnLaunch==`true`] | [0].SubnetId' \
  --output text)

SG_ID=$(aws ec2 describe-security-groups \
  --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

echo "  VPC: ${VPC_ID}, Subnet: ${SUBNET_ID}, SG: ${SG_ID}"

# --- Step 3: Create user data script ---
echo "[3/7] Preparing user data..."
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -euo pipefail

# Format and mount the data volume
mkfs.ext4 /dev/xvdb
mkdir -p /data/ollama
mount /dev/xvdb /data/ollama

# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Set model directory
export OLLAMA_MODELS=/data/ollama

# Start Ollama server
ollama serve &
sleep 10

# Pull all model tiers
echo "Pulling qwen3.5:27b (Tier 1 — Fallback)..."
ollama pull qwen3.5:27b

echo "Pulling qwen3-coder:30b-a3b (Tier 2 — Code)..."
ollama pull qwen3-coder:30b-a3b

echo "Pulling qwen3.5:122b-a10b (Tier 3 — Flagship)..."
ollama pull qwen3.5:122b-a10b

# Stop Ollama
pkill ollama || true
sleep 5

# Sync and unmount cleanly
sync
umount /data/ollama

# Signal completion
echo "MODEL_PULL_COMPLETE" > /tmp/model-pull-status
USERDATA
)

# --- Step 4: Launch instance with data volume ---
echo "[4/7] Launching ${INSTANCE_TYPE} instance..."

LAUNCH_ARGS=(
  --region "${REGION}"
  --image-id "${AMI_ID}"
  --instance-type "${INSTANCE_TYPE}"
  --subnet-id "${SUBNET_ID}"
  --security-group-ids "${SG_ID}"
  --associate-public-ip-address
  --block-device-mappings "[
    {
      \"DeviceName\": \"/dev/xvda\",
      \"Ebs\": {\"VolumeSize\": 30, \"VolumeType\": \"gp3\", \"DeleteOnTermination\": true}
    },
    {
      \"DeviceName\": \"/dev/xvdb\",
      \"Ebs\": {
        \"VolumeSize\": ${VOLUME_SIZE},
        \"VolumeType\": \"${VOLUME_TYPE}\",
        \"Iops\": ${VOLUME_IOPS},
        \"Throughput\": ${VOLUME_THROUGHPUT},
        \"DeleteOnTermination\": false,
        \"Encrypted\": true
      }
    }
  ]"
  --user-data "${USER_DATA}"
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ollama-model-snapshot-builder},{Key=Purpose,Value=model-snapshot}]"
  --query 'Instances[0].InstanceId'
  --output text
)

if [ -n "${KEY_NAME}" ]; then
  LAUNCH_ARGS+=(--key-name "${KEY_NAME}")
fi

INSTANCE_ID=$(aws ec2 run-instances "${LAUNCH_ARGS[@]}")
echo "  Instance: ${INSTANCE_ID}"

# --- Step 5: Wait for model pulls to complete ---
echo "[5/7] Waiting for model downloads (this may take 30-60 minutes)..."
echo "  Monitor progress: aws ssm start-session --target ${INSTANCE_ID}"

# Wait for instance to be running first
aws ec2 wait instance-running --region "${REGION}" --instance-ids "${INSTANCE_ID}"

# Poll for completion (check instance console output or use SSM)
MAX_WAIT=7200  # 2 hours max
ELAPSED=0
INTERVAL=120

while [ ${ELAPSED} -lt ${MAX_WAIT} ]; do
  # Check console output for completion marker
  CONSOLE=$(aws ec2 get-console-output \
    --region "${REGION}" \
    --instance-id "${INSTANCE_ID}" \
    --query 'Output' \
    --output text 2>/dev/null || echo "")

  if echo "${CONSOLE}" | grep -q "MODEL_PULL_COMPLETE"; then
    echo "  Models downloaded successfully!"
    break
  fi

  echo "  Still downloading... (${ELAPSED}s elapsed)"
  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ ${ELAPSED} -ge ${MAX_WAIT} ]; then
  echo "ERROR: Timed out waiting for model downloads."
  echo "Instance ${INSTANCE_ID} is still running. Check manually."
  exit 1
fi

# --- Step 6: Stop instance and snapshot the data volume ---
echo "[6/7] Stopping instance and creating snapshot..."

aws ec2 stop-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}" > /dev/null
aws ec2 wait instance-stopped --region "${REGION}" --instance-ids "${INSTANCE_ID}"

# Find the data volume (xvdb)
DATA_VOLUME_ID=$(aws ec2 describe-instances \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/xvdb`].Ebs.VolumeId' \
  --output text)

echo "  Data volume: ${DATA_VOLUME_ID}"

SNAPSHOT_ID=$(aws ec2 create-snapshot \
  --region "${REGION}" \
  --volume-id "${DATA_VOLUME_ID}" \
  --description "Ollama models: qwen3.5:27b, qwen3-coder:30b-a3b, qwen3.5:122b-a10b" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=ollama-models-snapshot},{Key=Models,Value=qwen3.5-27b_qwen3-coder-30b_qwen3.5-122b}]" \
  --query 'SnapshotId' \
  --output text)

echo "  Snapshot: ${SNAPSHOT_ID}"
echo "  Waiting for snapshot to complete..."
aws ec2 wait snapshot-completed --region "${REGION}" --snapshot-ids "${SNAPSHOT_ID}"

# --- Step 7: Terminate instance ---
echo "[7/7] Terminating instance..."
aws ec2 terminate-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}" > /dev/null

echo ""
echo "=== DONE ==="
echo ""
echo "Snapshot ID: ${SNAPSHOT_ID}"
echo ""
echo "Next steps:"
echo "  1. Update the PersistentVolume snapshot reference:"
echo "     snapshotID: \"${SNAPSHOT_ID}\""
echo "  2. Commit and push"
echo "  3. ArgoCD will sync the updated PV/PVC"
echo ""
echo "NOTE: EKS Auto Mode uses eks.amazonaws.com/v1 NodeClass which does"
echo "not support blockDeviceMappings. Model weights are attached via"
echo "PersistentVolume backed by this EBS snapshot, not via NodeClass."
