# Ollama-on-EKS: Improvement Recommendations & Approach

Review of the 9-improvement plan + dual-mode pipeline proposal, based on analysis of the current repo state.

---

## Assessment: What You Have Is Already Solid

Before jumping into improvements, it's worth acknowledging what's working well. Your current repo has a 4-layer architecture (Cloud → EKS → GitOps → Ollama) that's cleanly separated. Terraform is modular with 5 well-structured modules. ArgoCD manages everything via Git with proper wave orchestration (waves -2 through 6). CloudFront + WAF + API Gateway replaces Kong (99% cost reduction). You have operational scripts for scale-up/down, cert generation, and integration testing. The `claude-switch.sh` gives 3-mode access (remote/local/ollama). NetworkPolicy + Istio ambient mesh + internal NLB provide solid security foundations.

This isn't a from-scratch effort — it's hardening and productionising something that already works.

---

## Recommendations on Each of the 9 Improvements

### 1. Repo Structure & Terraform Modernisation

**Your plan is good, but I'd adjust scope.**

What you have already works: `terraform/modules/` exists with vpc, iam, eks, argocd, lb-controller. The structure is clean. Splitting into `environments/dev` and `environments/prod` makes sense but only when you actually have two environments — don't over-engineer prematurely.

**What I'd prioritise instead:**

- **S3 backend with DynamoDB locking** — do this first. You currently have `terraform.tfstate` committed locally (111KB). This is the most dangerous thing in the repo right now. One person runs `terraform apply` while another has stale state = destroyed infrastructure.

- **Pin Ollama image tag** — `ollama/ollama:latest` in `k8s/ollama/deployment.yaml` is a ticking time bomb. Pin to a specific version (e.g., `0.6.2`). This is a 5-minute fix with high impact.

- **Reconcile variable inconsistencies** — `variables.tf` defines `ollama_num_parallel = 4` but `deployment.yaml` hardcodes `OLLAMA_NUM_PARALLEL: "2"`. Same for context length and max loaded models. Either template the manifests or use ArgoCD's parameter overrides.

- **Move `.terraform/` and `*.tfstate*` to .gitignore** — these are already in `terraform/.gitignore` but verify nothing is tracked.

**What I'd defer:**

- `versent-` prefix on all resources — cosmetic, do it when you actually hit naming conflicts
- `k8s/base/` + `k8s/overlays/` Kustomize structure — only needed when you have multiple environments. Right now ArgoCD points directly at `k8s/` and it works fine

**Approach:** Single PR. Backend migration + image pinning + variable reconciliation. 1-2 hours of work.

---

### 2. Karpenter GPU Autoscaling (Scale-to-Zero)

**This is the highest-ROI improvement. Do it second (after state backend).**

Your current setup uses a static ASG for GPU nodes. You're paying for `g5.12xlarge` ($5.67/hr = $4,082/mo) 24/7 whether anyone is querying or not. Karpenter with `consolidateAfter: 30m` means you only pay when the model is in use, plus a 30-min idle buffer for workday breaks.

**My approach:**

1. Install Karpenter via the `terraform-aws-modules/eks/aws//modules/karpenter` submodule — this handles the IAM roles, SQS queue for interruption handling, and EventBridge rules
2. Create a `NodePool` for GPU workloads with `g5.xlarge` (not `g5.12xlarge`) for dev — the 122B model is overkill for development, `qwen3.5:27b` on a single A10G is more cost-effective for iteration
3. Keep `g5.12xlarge` as an option for prod where you need the 122B model
4. Set `consolidateAfter: 300s` (5 min) as you proposed
5. Add `capacity-type: spot` for dev NodePool (60% savings)

**On KEDA for pod-level scale-to-zero:** I'd hold off. Karpenter node-level consolidation already gives you scale-to-zero economics (no GPU node = no GPU cost). KEDA adds complexity and another component to maintain. The Ollama pod itself is lightweight — it's the node that costs money. Revisit KEDA only if you hit 10+ concurrent users and need horizontal pod scaling.

**Key dependency:** Remove the existing static GPU node group from `terraform/modules/eks/` when Karpenter takes over. Don't run both simultaneously — they'll fight over scheduling.

**Risk:** Cold start time. When Karpenter provisions a new GPU node, it takes 3-5 minutes (instance launch + driver init + kubelet registration + pod scheduling + model load from EBS). This is where EBS model snapshots (improvement #7) become important — they cut model load time from 10-20 min download to ~1-2 min disk read.

**Approach:** New Terraform module `modules/karpenter/`. Migrate GPU node group from static ASG to Karpenter NodePool. 4-6 hours of work including testing.

---

### 2b. EKS Auto Mode (Recommended Alternative to Manual Karpenter)

**This simplifies improvement #2 significantly. Consider using EKS Auto Mode instead of manually installing Karpenter.**

EKS Auto Mode (GA since Dec 2024, continuously enhanced through 2025-2026) bundles Karpenter, NVIDIA device plugin, Bottlerocket AMIs, and node lifecycle management into a single AWS-managed feature. You don't install, configure, or maintain any of these components — they're built into the EKS service.

**What EKS Auto Mode handles automatically:**

- **Karpenter** — fully managed, no IAM roles/SQS queues/EventBridge rules to create
- **NVIDIA device plugin + drivers** — pre-installed on Bottlerocket accelerated AMIs
- **AMI management** — automatic patching and security updates
- **SOCI parallel image pull** — up to 60% faster container startup (2025 feature)
- **Node health monitoring** — automatic detection of GPU/storage/network issues
- **KMS encryption** — ephemeral and root storage encrypted by default
- **EC2 capacity reservations** — guaranteed GPU access for production workloads

**What you still manage:** GPU NodePool YAML (~20 lines), Ollama deployment (unchanged), NetworkPolicy, ArgoCD, CloudFront + WAF + API Gateway (Terraform-managed), VPC/Terraform.

**GPU NodePool — this is all you need:**

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-ollama
spec:
  disruption:
    consolidateAfter: 30m     # Keep warm through short breaks
    consolidationPolicy: WhenEmpty
  template:
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default              # AWS-managed, no custom EC2NodeClass needed
      requirements:
      - key: "karpenter.sh/capacity-type"
        operator: In
        values: ["spot"]
      - key: "eks.amazonaws.com/instance-family"
        operator: In
        values: ["g5", "g6"]
      taints:
      - key: nvidia.com/gpu
        effect: NoSchedule
```

**Migration path:**

1. Create new EKS cluster with `computeConfig.enabled: true` (or enable on existing cluster)
2. Remove: NVIDIA device plugin manifest, Karpenter Terraform module, static GPU node group
3. Add GPU NodePool YAML above to `k8s/`
4. Redeploy Ollama — deployment YAML is unchanged
5. Verify GPU scheduling and scale-to-zero

**When NOT to use Auto Mode:** If you need custom AMIs with pre-baked model weights on the AMI itself (instead of EBS snapshots), or instance types not yet supported by Auto Mode. For everything else, Auto Mode is simpler and lower maintenance.

**Impact on Sprint 2:** This cuts Sprint 2 effort from 4-6 hours (manual Karpenter) to 2-3 hours (enable Auto Mode + NodePool YAML). You can delete the entire `modules/karpenter/` Terraform module and the NVIDIA device plugin manifest.

---

### 3. Network Policies & Air-Gap Enforcement

**Your plan is well-thought-out. One critical gap to address.**

Your current `k8s/ollama/networkpolicy.yaml` has ingress rules but **no egress rules**. This means the Ollama pod can currently reach the internet. For a data sovereignty claim, this is the most important thing to fix.

**My approach:**

- **Phase 1 (immediate):** Add egress rules to the existing NetworkPolicy — DNS only (port 53). This is a 10-line YAML change.

- **Phase 2 (with Karpenter):** Pre-load models via EBS snapshots so Ollama never needs internet access at all. Then you can drop even DNS egress if you want true air-gap.

- **Phase 3 (optional):** The full air-gapped Kustomize overlay with VPC endpoints and no NAT. Only do this when a client actually requires it — it adds significant complexity (VPC endpoints for ECR, S3, CloudWatch, STS all need Terraform resources + PrivateLink costs).

**On `verify-airgap.sh`:** Excellent idea. Simple to implement — `kubectl exec` into the Ollama pod and attempt `curl google.com`. Should fail. Run this in CI after every deployment. This is your auditable proof for clients.

**On `DATA-SOVEREIGNTY.md`:** Write this before implementing the full air-gap. The document is what clients actually see. Having it written first forces you to define exactly what "data sovereignty" means for your deployment before you build it.

**Approach:** Phase 1 is a quick win — add egress rules now (30 min). Phase 2 comes with Karpenter. Phase 3 only when a client demands it.

---

### 4. CloudFront + WAF + API Gateway (Replaces Kong)

**Architecture change: Replace Kong Cloud Gateway with AWS-native services.**

Kong Cloud Gateway costs ~$756/mo (Konnect Plus $300 + Transit Gateway $73 + Gateway pods $383) and adds a third-party control plane dependency. For a private LLM API with low-to-medium traffic, this is significantly over-engineered.

**New architecture:**

```
CloudFront (+ WAF + Shield Standard)
    ↓ HTTPS (AWS backbone, never public internet)
API Gateway (HTTP API, private)
    ↓ VPC Link
Internal NLB
    ↓ private subnet
Istio Gateway (mTLS)
    ↓
Ollama Pod
```

**Why this is better:**

- **Cost:** ~$6/mo vs ~$756/mo (99% reduction)
- **DDoS protection:** Shield Standard (free) + WAF rate limiting — Kong had no WAF at all
- **No Transit Gateway:** VPC Link is a direct private connection, eliminates TGW data processing charges
- **Fully Terraform-managed:** No external SaaS config (Konnect), no deck sync, no drift risk
- **WAF rules:** Rate limiting (100 req/5min per IP), IP allowlist, geo-blocking (AU/US), AWS Core Rule Set (SQLi/XSS), optional Bot Control

**Terraform modules to create:**

- `terraform/modules/api-gateway/` — HTTP API, VPC Link, NLB integration, routes, API key auth, usage plans
- `terraform/modules/cdn-waf/` — CloudFront distribution, WAF WebACL, Shield Standard, allowed IPs, geo-blocking

**What to remove:**

- `scripts/03-setup-cloud-gateway.sh` (Kong Konnect setup)
- `.github/workflows/kong-sync.yml` (deck config sync)
- Transit Gateway attachment in `terraform/main.tf`
- Kong-related ArgoCD waves

**OpenAI SDK compatibility preserved.** Clients use the CloudFront URL + API Gateway API key instead of Kong endpoint. Only the URL changes — drop-in replacement.

**Approach:** Create two Terraform modules (api-gateway + cdn-waf), remove Kong resources. 3-4 hours.

---

### 5. Open WebUI (Browser Chat Interface)

**Good addition, but deploy it as a separate ArgoCD Application, not inline.**

**My approach:**

1. Create `k8s/open-webui/` directory with deployment, service, PVC, networkpolicy
2. Add ArgoCD Application at Wave 5 (after Ollama is ready)
3. `OLLAMA_BASE_URL=http://ollama.ollama.svc.cluster.local:11434`
4. Encrypted PVC for conversation history (same StorageClass as Ollama)
5. Internal ALB or port-forward access only — never public

**Important security note you already flagged:** Open WebUI stores conversation history with customer data. Same NetworkPolicy as Ollama — zero internet egress. This is non-negotiable.

**What I'd disable in Open WebUI config:**
- Web search, community hub, image gen, update checks, telemetry (as you listed)
- Also disable: model downloading from Open WebUI UI (models should only be managed via kubectl/scripts, not by end users clicking buttons)

**Approach:** New K8s manifests + ArgoCD Application. 2-3 hours. Consider making it optional via a Terraform variable `enable_webui = true/false`.

---

### 6. Observability (Prometheus + Grafana + GPU Metrics) — IMPLEMENTED

**Status: Fully implemented.** Self-managed, air-gapped observability stack created as a Terraform module.

**Why self-managed (not AWS managed):** This cluster processes sensitive customer data. The air-gap principle applies to monitoring too — GPU metrics include pod names, namespaces, and workload patterns that reveal what's running for which client. Metrics stay in-cluster. No AMP (Amazon Managed Prometheus) or AMG (Amazon Managed Grafana) — both require egress to AWS endpoints.

**What's deployed:**

- **Prometheus** (`kube-prometheus-stack` v67.4.0) — 50Gi persistent storage, 15-day retention, 15s scrape interval
- **Grafana** — 3 bundled dashboards (GPU, Ollama API, Karpenter), air-gapped config (no internet calls, no update checks), dashboard JSON loaded via ConfigMaps
- **NVIDIA DCGM Exporter** (v4.2.3) — DaemonSet runs on GPU nodes only, ServiceMonitor for auto-discovery, tolerates nvidia.com/gpu taint
- **Alertmanager** — 6 alert rules across 3 groups (GPU, Ollama, Karpenter)

**Alert rules:**

| Alert | Condition | Severity |
|-------|-----------|----------|
| GPUMemoryHigh | GPU memory > 85% for 5 min | Warning |
| GPUMemoryCritical | GPU memory > 95% for 2 min | Critical |
| GPUTemperatureHigh | GPU temp > 85°C for 5 min | Warning |
| OllamaPodRestarts | > 2 restarts in 1 hour | Warning |
| OllamaUnavailable | 0 pods for 10+ min | Info |
| KarpenterProvisioningFailed | GPU node provision failed | Critical |

**Grafana dashboards (bundled, no internet needed):**

1. **GPU Metrics** — utilisation %, memory used/free, temperature, power draw, PCIe throughput
2. **Ollama API** — pod status, restarts, uptime, CPU/memory, API request rate/latency/errors
3. **Karpenter** — active GPU nodes, provision/termination events, cost estimation

**NetworkPolicy** (`k8s/monitoring-networkpolicy.yaml`) — blocks internet egress for all monitoring pods, allows intra-cluster scraping and DNS only.

**Files created:**

```
terraform/modules/observability/
├── main.tf                              # Helm releases + dashboard ConfigMaps
├── variables.tf                         # grafana_admin_password, retention, storage
├── outputs.tf                           # Service names for port-forward
├── versions.tf                          # Provider constraints
├── values/
│   ├── kube-prometheus-stack.yaml       # Prometheus + Grafana + Alertmanager config
│   └── dcgm-exporter.yaml              # NVIDIA GPU metrics DaemonSet
└── dashboards/
    ├── gpu-metrics.json                 # GPU dashboard
    ├── ollama-api-metrics.json          # Ollama API dashboard
    └── karpenter-metrics.json           # Node lifecycle + cost dashboard

k8s/monitoring-networkpolicy.yaml        # Air-gap enforcement
terraform/main.tf                        # Module wired as Layer 4
terraform/variables.tf                   # New observability variables
```

**Access Grafana:** `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` → open `http://localhost:3000` (admin / your password).

---

### 7. Cost Optimisation

**Most of this falls out naturally from improvements #2 and #6.**

- **Spot instances** — configured in Karpenter NodePool (improvement #2)
- **Scale-to-zero** — Karpenter consolidation (improvement #2)
- **EBS model snapshots** — this is the one standalone piece

**EBS snapshot approach:**

1. Launch a temporary GPU instance, pull the models you want
2. Create an EBS snapshot of the `/root/.ollama` volume
3. Reference the snapshot ID in Karpenter's `EC2NodeClass` block device mapping
4. New nodes boot with models already on disk — no download needed

This is critical for two reasons: cold start speed (2 min vs 20 min) and air-gap compliance (nodes don't need internet to get models).

**On `cost-report.sh`:** Good idea. Query AWS Cost Explorer API or just parse `kubectl get nodes` + instance type pricing. Low effort, high visibility.

**Approach:** EBS snapshot script + Karpenter EC2NodeClass config. 2-3 hours. Folded into improvement #2 work.

---

### 8. CI/CD (GitHub Actions)

**The Terraform CI is the missing piece.** (kong-sync.yml can be removed — Kong is replaced by Terraform-managed CloudFront + API Gateway.)

**My approach:**

- `terraform-plan.yml`: Trigger on PR to `terraform/**`. Run `terraform plan`, post as PR comment. Use OIDC federation for AWS credentials (no static keys — you're on the right track here).

- `terraform-apply.yml`: Trigger on merge to main. Require manual approval via GitHub Environment protection rules. Run `terraform apply`.

- **Add `verify-airgap.sh` as a post-deploy step** — this is your integration test. After apply succeeds, run the air-gap verification.

**One thing your plan is missing:** Terraform plan output can contain sensitive values (secrets, endpoints). Use `terraform plan -out=plan.bin` + `terraform show -no-color plan.bin` to get a safe-to-display summary, and avoid posting raw plan output in PR comments.

**Approach:** Two workflow files + OIDC setup. 3-4 hours.

---

### 9. Documentation

**Write DATA-SOVEREIGNTY.md first. Everything else follows.**

This is the document you show to clients. It should be written before you fully implement the air-gap because writing it forces you to define your security boundaries precisely. The implementation then proves the document's claims.

**Priority order:**
1. `DATA-SOVEREIGNTY.md` — architecture, network isolation, verification steps, compliance posture
2. `SETUP.md` — deployment from scratch (consolidate the existing script comments into a proper guide)
3. `CLIENT-INTEGRATION.md` — OpenAI SDK examples, Continue.dev, Open WebUI, curl
4. `COST-OPTIMISATION.md` — can be brief, mostly pointing to Karpenter config and scale scripts
5. `README.md` update — architecture diagram + quick start + data sovereignty statement prominent

**Approach:** Start with DATA-SOVEREIGNTY.md (2 hours). Others incrementally as features land.

---

## Dual-Mode Pipeline — Two Separate Stacks

**You deploy one or the other per engagement — not both, not a config flag.** Separate stacks ensure compliance by design. The air-gapped stack physically cannot reach a hosted LLM (no credentials, no egress rules, no API client to misconfigure). This eliminates human error as a data sovereignty risk.

### Stack A: Fully Air-Gapped

Phase 1 (analysis) and Phase 2 (report generation) both run on local Ollama/Qwen. Zero external API calls. No hosted LLM credentials provisioned. Egress blocked at NetworkPolicy level. Even a bug in the sanitisation layer can't leak data — there's no outbound path. Best for defence, healthcare, government.

### Stack B: Hybrid (Local + Bedrock)

Phase 1 always local — raw client data and code stays in EKS. Sanitisation layer (regex + LLM review) strips all client-identifiable data. Only sanitised findings JSON (no raw data, no code, no client identifiers) goes to the latest Claude Opus model via AWS Bedrock for Phase 2 report generation. Traffic stays on the AWS backbone via VPC endpoint — no public internet egress. Auth via IAM roles (IRSA), no API keys to rotate or leak. Best for consulting engagements where report quality is a differentiator.

**Why Bedrock?** Single cloud provider (one DPA, one audit trail via CloudTrail), IAM-native auth, VPC endpoint keeps traffic private, BAA coverage for healthcare engagements, and the latest Claude Opus model delivers frontier-quality structured analysis → polished report workflows.

### Why Separate Stacks, Not a Config Flag?

| Concern | Config Flag | Separate Stacks |
|---------|------------|-----------------|
| Human error | One wrong toggle sends data externally | Air-gapped stack has no egress path to misconfigure |
| Compliance audit | Auditor must verify runtime config | Auditor inspects Terraform — no hosted LLM resources exist |
| Credential exposure | API keys present even if unused | No API keys provisioned in air-gapped stack |
| Blast radius | Bug in sanitisation could leak silently | No outbound path — even a bug can't leak |

### Data Flow

```
Client Data → you deploy one stack or the other:

  Stack A (Fully Air-Gapped):
    Phase 1 (Ollama/Qwen) → Sanitisation → Phase 2 (Ollama/Qwen) → Good quality report

  Stack B (Hybrid):
    Phase 1 (Ollama/Qwen) → Sanitisation → Phase 2 (Latest Claude Opus via Bedrock, sanitised findings only) → High quality report
```

### Data Sovereignty Guarantee

| Data Type | Stack A (Air-Gapped) | Stack B (Hybrid) |
|-----------|---------------------|-----------------|
| Raw client data (code, docs, schemas) | Never leaves EKS | Never leaves EKS |
| Phase 1 analysis (raw findings) | Stays local | Stays local |
| Sanitised findings JSON | Stays local | Sent to Bedrock (abstract findings only — all client data, code, identifiers stripped) |
| Bedrock credentials | Not provisioned | IAM role (IRSA) — no API keys, no secrets to rotate |
| Egress to external APIs | Blocked at NetworkPolicy | VPC endpoint to Bedrock only — no public internet egress |

### Sanitisation Layer (Stack B Only)

Two-pass sanitisation ensures no raw client data or code reaches Bedrock:

1. **Regex pass:** Strip IPs, emails, API keys, AWS ARNs, JWTs, SSH keys, connection strings, file paths with usernames. BLOCKED_PATTERNS should be engagement-configurable with a deny-all default.
2. **LLM review pass:** Local Qwen reviews the sanitised JSON and flags semantic leakage (names, revenue figures, client-specific identifiers). Hard stop if raw data detected.

**What needs attention:**

- **Widen BLOCKED_PATTERNS:** Add AWS account IDs (`\b\d{12}\b`), ARNs (`arn:aws:\S+`), SSH keys, JWT tokens, connection strings. Start deny-all, allow known-safe patterns through.
- **Engagement creation UX:** Define how engagements are created — CLI, web UI, or script.
- **Separate Terraform compositions:** Shared modules, different root configs per stack. Each stack gets its own `terraform apply`.

**Recommendation:** Build infrastructure improvements (Sprints 1-3) first. Then build the orchestrator as a separate workstream — they have different failure modes and testing requirements.

---

## Revised Execution Order

Based on risk, ROI, and dependencies:

```
Sprint 1 (Foundation — 1 week)
├── 1a. S3 backend + state locking (CRITICAL — do first)
├── 1b. Pin Ollama image tag
├── 1c. Reconcile variable inconsistencies (TF vars ↔ K8s manifests)
├── 3a. Add egress NetworkPolicy rules (quick win)
└── 9a. Write DATA-SOVEREIGNTY.md (defines scope for everything else)

Sprint 2 (EKS Auto Mode + Cost Optimisation — 1 week)
├── 2b. Enable EKS Auto Mode (replaces manual Karpenter + NVIDIA plugin)
├── 2b. GPU NodePool YAML (~20 lines, scale-to-zero built in)
├── 7a. EBS model weight snapshots
├── 6a. DCGM Exporter + basic GPU dashboard
└── 3b. verify-airgap.sh script

Sprint 3 (Hardening — 1 week)
├── 4. CloudFront + WAF + API Gateway (replaces Kong)
├── 5. Open WebUI deployment
├── 6b. API metrics dashboards + alerting
└── 8. Terraform CI/CD (plan on PR, apply on merge)

Sprint 4 (Documentation + Polish — 1 week)
├── 9b. SETUP.md, CLIENT-INTEGRATION.md
├── 9c. README.md update
├── 1d. Environment separation (dev/prod) — only if needed
└── 3c. Air-gapped Kustomize overlay — only if client requires

Separate Workstream (Parallel)
└── Dual-mode orchestrator (containerised, separate CI, own test suite)
```

---

## Top 5 Things I'd Fix Before Anything Else

These are quick wins (under 1 hour each) with disproportionate risk reduction:

1. **Move Terraform state to S3** — local state file = data loss risk and collaboration blocker
2. **Pin `ollama/ollama:latest` to a specific version** — non-deterministic deployments
3. **Add egress rules to NetworkPolicy** — your data sovereignty claim has a gap without this
4. **Reconcile `OLLAMA_NUM_PARALLEL` (2 in YAML vs 4 in TF vars)** — misconfiguration waiting to surprise you
5. **Add `verify-airgap.sh`** — auditable proof that the air-gap works

Each of these is a single commit. Total time: half a day.

---

## Questions Before Starting Implementation

1. **Do you have a second AWS account for dev/prod separation?** This determines whether environment separation (improvement 1) is needed now or later.

2. **What's the target model for day-to-day use?** The plan references `qwen3.5:122b` (needs g5.12xlarge, 96GB VRAM) but also `qwen3.5:9b` and `qwen3.5:27b`. If the 27b model is sufficient, you can drop to `g5.xlarge` (24GB VRAM, $1.01/hr) — that's 5.6x cheaper.

3. **How many concurrent users do you expect?** 1-3 users = single pod is fine. 5+ = consider horizontal scaling (which changes the Karpenter and Ollama config significantly).

4. **Is there an existing identity provider (Okta, Azure AD, Google Workspace)?** This determines SSO setup for Open WebUI and API Gateway consumer management.

5. **When does the first client engagement using this stack start?** This sets the deadline for Sprint 1-2 (must be done) vs Sprint 3-4 (nice to have).

---

## Model Tier Strategy: One at a Time, Not All at Once

**Don't run all models simultaneously — it's wasteful.** Ollama only loads one model into GPU memory at a time. Loading a second evicts the first. Paying for a g5.12xlarge ($1.90/hr) while only one model is active wastes 80%+ of GPU capacity.

### Three Tiers Available

| Tier | Model | Type | VRAM | GPU Instance | Spot Cost | Quality |
|------|-------|------|------|-------------|-----------|---------|
| 1 (Fallback) | `qwen3.5:27b` | Dense, 27B | ~18GB | g5.xlarge (1x A10G) | $0.35/hr | SWE-bench 72.4% (ties GPT-5 mini) |
| 2 (Code) | `qwen3-coder:30b-a3b` | MoE, 3.3B active | ~20GB | g5.xlarge (1x A10G) | $0.35/hr | Code-specialised, very fast inference |
| 3 (Default) | `qwen3.5:122b-a10b` | MoE, 10B active | ~72GB | g5.12xlarge (4x A10G) | $1.90/hr | Beats GPT-5 mini on tool use (+30%) |

### Cost-Effective Approach

- **Download all 3 to EBS** — models on disk cost ~$5-10/mo total (cheap storage)
- **Only load one at a time** — GPU cost is only when a model is actively in memory
- **Karpenter auto-provisions the right GPU** — Tier 3 (default) triggers g5.12xlarge, Tier 1 triggers g5.xlarge
- **30-min idle window** — node stays warm through short breaks, terminates after 30 min idle

### Monthly Cost Comparison

| Approach | Monthly Cost | Verdict |
|----------|-------------|---------|
| All 3 on g5.12xlarge 24/7 | $4,082 | Wasteful |
| **Flagship default, scale-to-zero, 30-min idle** | **~$334/mo** | **Chosen** |
| Flagship + Tier 1 fallback for quick tasks | ~$250-300/mo | Alternative |
| Tier 1 only | ~$56 | Cheapest |

### Recommended Daily Workflow (Flagship Default)

1. **Start your day with Flagship** (`claude --model qwen3.5:122b-a10b`) — maximum quality, beats GPT-5 mini on tool use (+30%). ~3 min cold start on first request, then instant.
2. **Optionally drop to Tier 1 for quick iteration** (`claude --model qwen3.5:27b`) — faster tokens (50-80 vs 30-50 tok/s), 5.6x cheaper instance. Good for rapid prototyping, debugging, simple edits.
3. **30-min idle window keeps node warm** — coffee breaks, meetings, context switches all covered.
4. **Stop working → cost goes to $0** — node terminates after 30 min idle.

### Switching Command

```bash
# Default — flagship (no flag needed if configured as default)
claude --model qwen3.5:122b-a10b    # Tier 3: flagship (DEFAULT)

# Drop to cheaper tier for quick tasks
claude --model qwen3.5:27b          # Tier 1: fast, cheap fallback
claude --model qwen3-coder:30b-a3b  # Tier 2: code-specialist

# Or use the switch script
./switch-model.sh use 3   # Tier 3 (default)
./switch-model.sh use 1   # Tier 1 (fallback)
./switch-model.sh status   # What's currently loaded?
```

### Spot Instance Fallback

The NodePool specifies `["spot", "on-demand"]` — Karpenter tries spot first, falls back to on-demand automatically if spot is unavailable. No user intervention needed.

- **Spot unavailable at launch:** Karpenter retries with on-demand (+10-15s), user sees on-demand pricing ($5.67/hr vs $1.90/hr) until spot is available
- **Spot reclaimed mid-session:** AWS gives 2-min warning via SQS, Karpenter provisions a replacement node in parallel, ~2-3 min interruption (model reloads from EBS snapshot). Rare — g5 spot interruption rate in ap-southeast-2 is typically <5%

**No manual tier up/down needed** — with EKS Auto Mode + Karpenter, the GPU instance type changes automatically based on which model you load. Karpenter sees the pod's resource request, provisions the right-sized node, and terminates it when idle.

---

## Gap Implementation Plan

8 gaps identified during audit. 1 fully implemented (observability), 7 with detailed implementation plans below.

### Gap 1 (Critical): Local terraform.tfstate → S3 Backend

**Risk:** State file stored locally (111KB). Concurrent applies = state corruption = destroyed infrastructure.

**Fix:** Create `terraform/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "ollama-eks-tfstate-<ACCOUNT_ID>"
    key            = "ollama-eks/terraform.tfstate"
    region         = "ap-southeast-2"
    encrypt        = true
    dynamodb_table = "ollama-eks-tfstate-lock"
  }
}
```

Bootstrap: Create S3 bucket (versioned) + DynamoDB table before `terraform init -migrate-state`. Effort: 1 hour. Sprint 1.

### Gap 2 (Critical): Ollama Egress Open → DNS-Only NetworkPolicy

**Risk:** `k8s/ollama/networkpolicy.yaml` allows egress to `0.0.0.0/0:443`. Breaks air-gap.

**Fix:** Replace egress rules to allow only DNS (port 53) and intra-cluster traffic. Block all internet access. Verify with `kubectl exec -n ollama deploy/ollama -- curl -s --max-time 5 https://google.com` (should timeout). Effort: 30 min. Sprint 1.

### Gap 3 (High): Ollama Image Unpinned → Pin to v0.6.2

**Risk:** `ollama/ollama:latest` can silently pull breaking changes.

**Fix:** Change to `ollama/ollama:0.6.2@sha256:<digest>` with `imagePullPolicy: IfNotPresent`. Effort: 5 min. Sprint 1.

### Gap 4 (High): OLLAMA_NUM_PARALLEL Mismatch → Reconcile

**Risk:** TF says 4, K8s manifest says 2. Confusing — which is truth?

**Fix:** Update `k8s/ollama/deployment.yaml` to `OLLAMA_NUM_PARALLEL: "4"`. Remove TF variables for Ollama env vars (they're not used in Terraform). Effort: 15 min. Sprint 1.

### Gap 5 (Medium): No GPU Metrics → IMPLEMENTED

See Section 6 above. Full Prometheus + Grafana + DCGM Exporter stack deployed.

### Gap 6 (Medium): Self-Signed TLS → cert-manager

**Risk:** Manual openssl cert with 365-day expiry. No rotation, no alerting.

**Fix:** Deploy cert-manager via Terraform Helm release. Create ClusterIssuer (self-signed CA for internal, Let's Encrypt for external). Certificates auto-renew 30 days before expiry. Effort: 2 hours. Sprint 3.

### Gap 7 (Medium): Static GPU ASG → Karpenter/Auto Mode NodePool

**Risk:** Paying $4,082/mo for g5.12xlarge 24/7.

**Fix:** EKS Auto Mode NodePool YAML with 30-min idle window (`consolidateAfter: 30m`), spot instances, instance types `[g5.xlarge, g5.2xlarge, g5.12xlarge]`. GPU nodes stay warm through short breaks, then auto-terminate. Effort: 30 min. Sprint 2.

### Gap 8 (Medium): No Terraform CI/CD → GitHub Actions

**Risk:** Manual `terraform apply` from laptops. No review, no audit trail.

**Fix:** Two workflows: `terraform-plan.yml` (on PR, posts plan as comment) and `terraform-apply.yml` (on merge to main, requires manual approval via GitHub Environment). OIDC federation for AWS credentials. Post-deploy runs `verify-airgap.sh`. Effort: 3 hours. Sprint 3.

### Summary

| Gap | Severity | Status | Sprint | Effort |
|-----|----------|--------|--------|--------|
| 1. S3 Backend | Critical | PLANNED | Sprint 1 | 1 hr |
| 2. Egress NetworkPolicy | Critical | PLANNED | Sprint 1 | 30 min |
| 3. Pin Image | High | PLANNED | Sprint 1 | 5 min |
| 4. Reconcile NUM_PARALLEL | High | PLANNED | Sprint 1 | 15 min |
| 5. GPU Observability | Medium | **DONE** | — | — |
| 6. TLS Automation | Medium | PLANNED | Sprint 3 | 2 hrs |
| 7. GPU NodePool | Medium | PLANNED | Sprint 2 | 30 min |
| 8. Terraform CI/CD | Medium | PLANNED | Sprint 3 | 3 hrs |

**Total implementation effort:** ~7 hours across Sprints 1-3.

---

## Cold Start Mitigation (Fix 1 + Fix 2 + 30-Min Idle Window)

With scale-to-zero, the first request after idle waits for a GPU node to launch, bootstrap, and load the model. Without mitigation this takes 15-25 minutes. With the fixes below + a 30-min idle window, cold starts drop to ~3 minutes and most workday breaks have zero wait.

### Where the Time Goes

| Stage | Duration | Notes |
|-------|----------|-------|
| 1. Karpenter detects pending pod → calls EC2 API | ~5s | Fast |
| 2. EC2 GPU instance provisioning | 30-60s | AWS infra time, can't reduce |
| 3. Node bootstrap + joins EKS | 60-90s | EKS Auto Mode AMI is pre-optimised |
| 4. NVIDIA drivers + device plugin ready | 15-30s | Pre-installed in EKS GPU AMI |
| 5. Ollama pod starts | 15s | `imagePullPolicy: IfNotPresent` |
| 6. **Model loads into GPU VRAM** | **60-90s** | **With Fix 1 + 2 (was 15-25 min)** |
| **Total** | **~3 min** | **Down from 15-25 min** |

### Fix 1: EBS Snapshots (Eliminates Model Download)

Pre-download all models to an EBS volume, snapshot it, reference the snapshot ID in Karpenter EC2NodeClass. New nodes boot with models already on disk — no internet needed.

**Script:** `scripts/create-model-snapshot.sh` — launches a temporary GPU instance, downloads all 3 model tiers, creates an EBS snapshot, terminates the instance. Run once, update snapshot ID when models change.

**EC2NodeClass config:**

```yaml
# k8s/nodepools/gpu-ec2nodeclass.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-ollama
spec:
  blockDeviceMappings:
    - deviceName: /dev/xvdb
      ebs:
        volumeType: gp3
        volumeSize: "200Gi"
        iops: 6000            # Fix 2: 2x default
        throughput: 400        # Fix 2: 3.2x default (125 → 400 MB/s)
        encrypted: true
        snapshotID: "snap-0abc123def456"   # Fix 1: pre-loaded models
        deleteOnTermination: true
  userData: |
    #!/bin/bash
    mkdir -p /data/ollama
    mount /dev/xvdb /data/ollama
    echo 'OLLAMA_MODELS=/data/ollama' >> /etc/environment
```

### Fix 2: High-Throughput gp3

Default gp3 throughput is 125 MB/s. A 70GB model at 125 MB/s = ~9 min for the disk read. At 400 MB/s it drops to ~3 min. Cost: ~$4/mo extra.

### 30-Minute Idle Window

`consolidateAfter: 30m` — node stays warm for 30 minutes after the last request. Covers coffee breaks, short meetings, and context switches. Cost: ~$0.18 per idle period (g5.xlarge spot) or ~$0.95 (g5.12xlarge spot). Cold start only happens after 30+ minutes away.

### Cold Start Scenarios

| Scenario | Wait | Why |
|----------|------|-----|
| Back from 10-min coffee break | 0s | Node still warm (30-min window) |
| Back from 25-min meeting | 0s | Node still warm (30-min window) |
| Back from 1-hour lunch | ~3 min | Node terminated, cold start via snapshot |
| First request of the day | ~3 min | Full cold start (snapshot + gp3) |
| Switch Tier 1 → 3 (same GPU fits) | 10-30s | Model on disk, just VRAM load |
| Switch Tier 1 → 3 (needs bigger GPU) | ~3 min | New g5.12xlarge node via snapshot |

### Cost Impact

| Component | Without Fixes | With Fixes |
|-----------|--------------|------------|
| GPU compute (8hrs/day, spot) | $304/mo | $304/mo |
| Idle window overhead (30min × ~4 breaks/day) | $0 | ~$16/mo |
| EBS snapshot storage (200GB) | $0 | ~$10/mo |
| gp3 throughput upgrade | $0 | ~$4/mo |
| **Total** | **$304/mo + 15-25 min cold starts** | **~$334/mo + 3 min cold starts** |

**+$30/mo** for 80% faster cold starts, zero wait during workday breaks, air-gap compliant model loading, and models that persist across node restarts.

### Snapshot Refresh

Re-run `create-model-snapshot.sh` when adding new models or updating Ollama. Create new snapshot → update `snapshotID` in EC2NodeClass → Karpenter uses it for next node launch. Recommend monthly refresh.
