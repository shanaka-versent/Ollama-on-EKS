# Ollama on EKS - Terraform IaC

Deploy a fully private Ollama LLM server on AWS EKS with GPU acceleration using Terraform. Your code and prompts travel encrypted from your Mac to your own AWS account, processed by an open-source model you control. No third-party LLM provider is involved.

---

## Architecture

```
┌──────────────────────────┐                           ┌──────────────────────────────────────────┐
│        YOUR MAC          │    kubectl port-forward    │        YOUR AWS ACCOUNT (EKS)            │
│                          │    (encrypted tunnel)      │                                          │
│  Terminal 1:             │                            │  Layer 1: Cloud Foundations               │
│  kubectl port-forward    │                            │  ┌────────────────────────────────────┐  │
│  -n ollama svc/ollama    │                            │  │ VPC (10.0.0.0/16)                  │  │
│  11434:11434             │                            │  │ 2x Public Subnets + IGW            │  │
│                          │                            │  │ 2x Private Subnets + NAT Gateway   │  │
│  Terminal 2:             │                            │  └────────────────────────────────────┘  │
│  claude --model          │                            │                                          │
│  qwen2.5-coder:32b      │                            │  Layer 2: EKS Cluster                    │
│                          │                            │  ┌────────────────────────────────────┐  │
│  Claude Code talks to    │   localhost:11434           │  │ EKS Control Plane (K8s 1.31)       │  │
│  localhost:11434 and     │ ──────────────────────────▶│  │ System Nodes: 2x t3.medium         │  │
│  thinks it's local       │                            │  │ GPU Nodes:    1x g5.12xlarge        │  │
│                          │                            │  │               (4x NVIDIA A10G GPUs) │  │
│                          │                            │  │ EBS CSI Driver (IRSA)               │  │
│                          │                            │  │ OIDC Provider                       │  │
└──────────────────────────┘                            │  └────────────────────────────────────┘  │
                                                        │                                          │
                                                        │  Layer 3: Ollama Deployment               │
                                                        │  ┌────────────────────────────────────┐  │
                                                        │  │ NVIDIA Device Plugin (DaemonSet)   │  │
                                                        │  │ GP3 StorageClass + 200GB PVC       │  │
                                                        │  │ Ollama Deployment (4 GPUs)         │  │
                                                        │  │ ClusterIP Service (internal only)  │  │
                                                        │  │ NetworkPolicy (locked down)        │  │
                                                        │  │ Model Loader Job (auto-pull)       │  │
                                                        │  └────────────────────────────────────┘  │
                                                        └──────────────────────────────────────────┘
```

**What runs where:**

| Component | Where | Role |
|---|---|---|
| Claude Code | Your Mac | Agent framework — reads files, edits code, runs commands |
| kubectl port-forward | Your Mac to AWS | Encrypted tunnel making remote Ollama appear as localhost |
| Ollama server | EKS pod (your AWS) | Model server — loads model, runs GPU inference |
| qwen2.5-coder:32b | EKS pod (your AWS) | The actual LLM brain doing the reasoning |

---

## Prerequisites

### 1. Install CLI Tools

```bash
brew install awscli
brew install terraform
brew install kubectl
```

### 2. Configure AWS Credentials

```bash
aws configure
# Enter: AWS Access Key ID, Secret Key, Region (e.g., us-west-2), Output format (json)
```

Verify:

```bash
aws sts get-caller-identity
# You should see your AWS account ID
```

### 3. Verify Claude Code is Installed

```bash
claude --version
# If not installed: npm install -g @anthropic-ai/claude-code
```

### 4. GPU Instance Quota

Ensure your AWS account has quota for GPU instances in your target region. Check at:
**AWS Console > Service Quotas > EC2 > Running On-Demand G and VT instances**

For `g5.12xlarge` you need at least 48 vCPUs. Request a quota increase if needed — this can take a few hours.

---

## Quick Start

```bash
cd terraform

# 1. Initialize Terraform
terraform init

# 2. Review what will be created
terraform plan

# 3. Deploy everything (~20 min for EKS + GPU node)
terraform apply

# 4. Get cluster credentials
$(terraform output -raw eks_get_credentials_command)

# 5. Verify the cluster is running
kubectl get nodes
# Should show system nodes + GPU node

# 6. Start the tunnel (keep this terminal open)
kubectl port-forward -n ollama svc/ollama 11434:11434

# 7. In another terminal — run Claude Code with your private LLM
ANTHROPIC_BASE_URL=http://localhost:11434 \
ANTHROPIC_AUTH_TOKEN=ollama \
ANTHROPIC_API_KEY="" \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
claude --model qwen2.5-coder:32b
```

After `terraform apply` completes, run `terraform output connect_to_ollama` for a full connection cheat sheet.

---

## What Terraform Creates

### Layer 1: Cloud Foundations (`modules/vpc`)

| Resource | Details |
|----------|---------|
| VPC | `10.0.0.0/16` with DNS hostnames enabled |
| Public Subnets | 2x across AZs, auto-assign public IP, tagged for ELB |
| Private Subnets | 2x across AZs, tagged for internal ELB |
| Internet Gateway | Outbound internet for public subnets |
| NAT Gateway | Outbound internet for private subnets (single NAT) |
| Route Tables | Public routes via IGW, private routes via NAT |

### Layer 2: EKS Cluster (`modules/iam`, `modules/eks`)

| Resource | Details |
|----------|---------|
| IAM Roles | Cluster role (EKS service), Node role (EC2 workers), EBS CSI IRSA role |
| EKS Cluster | Kubernetes 1.31, public + private API endpoint |
| OIDC Provider | Enables IRSA (IAM Roles for Service Accounts) |
| System Node Group | 2x `t3.medium`, tainted `CriticalAddonsOnly` — only system pods run here |
| GPU Node Group | 1x `g5.12xlarge` (4x NVIDIA A10G, 96GB VRAM), tainted `nvidia.com/gpu` — only GPU workloads schedule here, scalable 0-2 |
| EKS Addons | VPC-CNI, CoreDNS, kube-proxy, EBS CSI Driver |

### Layer 3: Ollama Deployment (`modules/ollama`)

| Resource | Details |
|----------|---------|
| Namespace | `ollama` with purpose labels |
| GP3 StorageClass | EBS gp3 with 4000 IOPS, 250 MB/s throughput, volume expansion enabled |
| PVC | 200GB for model storage (persists across pod restarts) |
| NVIDIA Device Plugin | Helm chart — enables K8s GPU scheduling on the GPU nodes |
| Deployment | Ollama container with 4 GPUs, 96GB memory limit, health checks |
| Service | ClusterIP on port 11434 — **never exposed to internet** |
| NetworkPolicy | Ingress: cluster-internal only. Egress: DNS + HTTPS (model pulls) |
| Model Loader Job | Auto-pulls `qwen2.5-coder:32b` after deployment |

---

## GPU Instance Options

Edit `terraform.tfvars` to change the GPU instance:

| Instance | GPUs | VRAM | Best For | Cost/hr |
|----------|------|------|----------|---------|
| `g5.xlarge` | 1x A10G | 24GB | 7B models | ~$1.01 |
| `g5.2xlarge` | 1x A10G | 24GB | 7B-14B models | ~$1.21 |
| `g5.12xlarge` | 4x A10G | 96GB | 32B-70B models | ~$5.67 |
| `p4d.24xlarge` | 8x A100 | 320GB | 70B+ models | ~$32.77 |

When changing instance type, update these variables together in `terraform.tfvars`:

```hcl
# Example: Switch to g5.xlarge for smaller/cheaper models
gpu_node_instance_type = "g5.xlarge"
gpu_count              = 1
ollama_memory_limit    = "20Gi"
ollama_memory_request  = "16Gi"
ollama_cpu_limit       = 4
ollama_cpu_request     = 2
ollama_model           = "qwen2.5-coder:7b"
```

**GPU count by instance type:**

| Instance | `gpu_count` |
|----------|-------------|
| g5.xlarge / g5.2xlarge | `1` |
| g5.12xlarge | `4` |
| p4d.24xlarge | `8` |

---

## Configuration Reference

All variables are in `terraform.tfvars`. Key configuration groups:

### General

| Variable | Default | Description |
|----------|---------|-------------|
| `region` | `us-west-2` | AWS region |
| `environment` | `dev` | Environment name (used in resource naming) |
| `project_name` | `ollama` | Project name prefix |

### Network

| Variable | Default | Description |
|----------|---------|-------------|
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `az_count` | `2` | Number of availability zones |
| `enable_nat_gateway` | `true` | NAT Gateway for private subnets |

### EKS

| Variable | Default | Description |
|----------|---------|-------------|
| `kubernetes_version` | `1.31` | Kubernetes version |
| `system_node_instance_type` | `t3.medium` | System node instance type |
| `system_node_count` | `2` | System node count |
| `gpu_node_instance_type` | `g5.12xlarge` | GPU instance type |
| `gpu_node_count` | `1` | GPU node count |
| `gpu_node_min_count` | `0` | Minimum GPU nodes (0 = allow scale to zero) |
| `gpu_node_max_count` | `2` | Maximum GPU nodes |
| `gpu_capacity_type` | `ON_DEMAND` | `ON_DEMAND` or `SPOT` (Spot saves ~60%) |

### Ollama

| Variable | Default | Description |
|----------|---------|-------------|
| `ollama_model` | `qwen2.5-coder:32b` | Model to auto-pull |
| `model_storage_size` | `200Gi` | EBS volume size for models |
| `gpu_count` | `4` | GPUs allocated to Ollama |
| `ollama_memory_limit` | `96Gi` | Container memory limit |
| `ollama_keep_alive` | `24h` | Keep models loaded in memory |
| `ollama_num_parallel` | `4` | Parallel inference requests |
| `ollama_max_loaded_models` | `2` | Max models in memory simultaneously |
| `auto_pull_model` | `true` | Auto-pull model after deployment |

---

## Daily Usage

### Starting your day

```bash
# Terminal 1: Start the tunnel
kubectl port-forward -n ollama svc/ollama 11434:11434

# Terminal 2: Use Claude Code with private LLM
ANTHROPIC_BASE_URL=http://localhost:11434 \
ANTHROPIC_AUTH_TOKEN=ollama \
ANTHROPIC_API_KEY="" \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
claude --model qwen2.5-coder:32b
```

Or set up a permanent alias in `~/.zshrc`:

```bash
alias claude-private='ANTHROPIC_BASE_URL=http://localhost:11434 ANTHROPIC_AUTH_TOKEN=ollama ANTHROPIC_API_KEY="" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude --model qwen2.5-coder:32b'
alias claude-remote='claude'
```

Then simply: `claude-private`

### Adding more models

```bash
kubectl exec -n ollama deploy/ollama -- ollama pull llama3.1:70b
kubectl exec -n ollama deploy/ollama -- ollama pull codestral:22b
kubectl exec -n ollama deploy/ollama -- ollama list
```

### Checking GPU status

```bash
kubectl exec -n ollama deploy/ollama -- nvidia-smi
```

---

## Cost Management

### Monthly cost estimates

| Component | 24/7 | 8 hrs/day weekdays | 8 hrs/day Spot |
|-----------|------|--------------------|----------------|
| EKS Control Plane | ~$73 | ~$73 | ~$73 |
| g5.12xlarge | ~$4,082 | ~$907 | ~$304 |
| EBS 200GB gp3 | ~$18 | ~$18 | ~$18 |
| **Total** | **~$4,173** | **~$998** | **~$395** |

### Scale to zero (stop GPU billing)

```bash
# Scale down Ollama pod
kubectl scale deployment ollama -n ollama --replicas=0

# Scale GPU node group to 0 instances
aws eks update-nodegroup-config \
  --cluster-name $(terraform output -raw eks_cluster_name) \
  --nodegroup-name $(terraform output -raw gpu_node_group_name) \
  --scaling-config minSize=0,maxSize=2,desiredSize=0 \
  --region us-west-2
```

### Resume next day

```bash
# Scale GPU node back up (~3-5 min for node to be ready)
aws eks update-nodegroup-config \
  --cluster-name $(terraform output -raw eks_cluster_name) \
  --nodegroup-name $(terraform output -raw gpu_node_group_name) \
  --scaling-config minSize=0,maxSize=2,desiredSize=1 \
  --region us-west-2

# Wait for node
kubectl get nodes -w

# Scale Ollama back
kubectl scale deployment ollama -n ollama --replicas=1
kubectl wait --for=condition=ready pod -l app=ollama -n ollama --timeout=300s

# Models persist on EBS — no re-download needed!
```

### Use Spot instances (save ~60%)

Change in `terraform.tfvars`:

```hcl
gpu_capacity_type = "SPOT"
```

Then `terraform apply`. Spot instances can be reclaimed by AWS with 2 minutes notice, so only use for development — not production inference.

---

## Security

| Layer | Protection |
|-------|-----------|
| **Ollama Service** | `ClusterIP` — never exposed to internet |
| **NetworkPolicy** | Ingress: cluster-internal only on port 11434. Egress: DNS + HTTPS only (model pulls) |
| **Connection** | `kubectl port-forward` — encrypted via kubeconfig TLS certificate |
| **Claude Code** | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` — no telemetry |
| **AWS VPC** | Private subnets for nodes, NAT Gateway for outbound only |
| **Node Isolation** | System nodes tainted `CriticalAddonsOnly`, GPU nodes tainted `nvidia.com/gpu` — workloads cannot cross-schedule |
| **EBS Storage** | gp3 volume with `Retain` reclaim policy — data survives pod deletion |
| **IRSA** | EBS CSI Driver uses scoped IAM role via OIDC — no broad node permissions |

**Result:** Your code and prompts travel encrypted from your Mac to your own AWS account, processed by an open-source model you control. No third-party LLM provider is involved.

---

## Troubleshooting

| Problem | Diagnosis | Fix |
|---------|-----------|-----|
| Pod stuck in `Pending` | `kubectl describe pod -n ollama -l app=ollama` | GPU node not ready — wait or check nodegroup status |
| `Insufficient nvidia.com/gpu` | Node doesn't have GPU device plugin | Wait for NVIDIA plugin DaemonSet: `kubectl get ds -n kube-system` |
| Model pull fails | `kubectl exec -n ollama deploy/ollama -- df -h /root/.ollama` | Disk full — increase `model_storage_size` in tfvars |
| Port-forward drops | Connection timeout | Re-run the port-forward command. For auto-reconnect, use a loop: `while true; do kubectl port-forward -n ollama svc/ollama 11434:11434; sleep 2; done` |
| Slow inference | `kubectl exec -n ollama deploy/ollama -- nvidia-smi` | Check GPU utilization — model may be running on CPU if GPUs aren't detected |
| Claude Code outputs raw JSON | Model too small for tool-use protocol | Use 32B+ model, not 7B |
| `model not found` in Claude Code | Model name mismatch | Run `kubectl exec -n ollama deploy/ollama -- ollama list` to check exact name |
| EBS CSI issues | `kubectl describe pvc -n ollama` | Check EBS CSI driver pod: `kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver` |
| Terraform circular dependency | Dependency graph error | The EBS CSI IRSA role depends on EKS OIDC — this is handled by creating EKS first, then the IRSA role, then the addon |
| GPU quota exceeded | AWS `InsufficientInstanceCapacity` | Request GPU quota increase in AWS Console > Service Quotas > EC2 |

### Useful debugging commands

```bash
# Check all pods
kubectl get pods -A

# Check GPU node labels and taints
kubectl describe node -l nvidia.com/gpu.present=true

# Check Ollama logs
kubectl logs -n ollama deploy/ollama -f

# Check model loader job
kubectl logs -n ollama job/ollama-model-loader

# Check NVIDIA plugin
kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin

# Test Ollama directly
kubectl exec -n ollama deploy/ollama -- curl -s localhost:11434/api/tags
```

---

## Tear Down

```bash
# Destroy everything (VPC, EKS, nodes, Ollama)
terraform destroy
```

**Note:** The EBS volume uses `Retain` reclaim policy. After `terraform destroy`, the PV may still exist in AWS. Check and manually delete if needed:

```bash
aws ec2 describe-volumes --filters "Name=tag:Project,Values=Ollama-Private-LLM" --region us-west-2
```

---

## Terraform Dependency Chain

```
vpc + iam ──────────────────┐
  (parallel, no deps)       │
                            ▼
                   eks (needs vpc subnets + iam roles)
                            │
                            ▼
                   iam_ebs_csi (needs eks OIDC provider)
                            │
                            ▼
                   aws_eks_addon.ebs_csi (needs eks + iam_ebs_csi)
                            │
                            ▼
                   ollama (needs eks + ebs_csi addon)
```

---

## Terraform Outputs

After `terraform apply`, these outputs are available:

| Output | Description |
|--------|-------------|
| `eks_cluster_name` | EKS cluster name |
| `eks_cluster_endpoint` | EKS API endpoint |
| `eks_get_credentials_command` | Command to configure kubectl |
| `gpu_node_group_name` | GPU node group name (for scaling commands) |
| `ollama_namespace` | Kubernetes namespace |
| `ollama_cluster_url` | In-cluster URL for Ollama |
| `ollama_port_forward_command` | kubectl port-forward command |
| `connect_to_ollama` | Full connection cheat sheet |

```bash
# Print all outputs
terraform output

# Print the connection guide
terraform output connect_to_ollama
```
