# CLAUDE.md — Project Context for Claude Code

This file gives Claude Code the context and requirements to implement changes in this repo.

---

## What This Repo Is

A fully private, air-gapped LLM inference platform on AWS EKS. Ollama serves Qwen 3.5 models on GPU nodes, exposed via CloudFront + WAF + API Gateway. Prompts and source code never leave the AWS account. Designed for consulting engagements where client data sovereignty is non-negotiable.

## Architecture (4 Layers)

Layer 1 — VPC (10.0.0.0/16) with private/public subnets + NAT Gateway.
Layer 2 — EKS Control Plane + system node group (t3.medium) + GPU node group (g5.12xlarge, 4x A10G). EBS CSI Driver + AWS LB Controller.
Layer 3 — ArgoCD with wave orchestration (waves 0-6). Wave 0: Istio + NVIDIA Plugin → Wave 1-2: Namespaces + Storage → Wave 3-4: Ollama + Model Loader → Wave 5-6: Gateway + Routes.
Layer 4 — CloudFront (+ WAF + Shield Standard) → API Gateway (REST API, native API key auth) → VPC Link → Internal NLB → Istio Gateway (mTLS) → Ollama Pod.

Traffic flow (API): Client → CloudFront (WAF) → API Gateway (x-api-key) → VPC Link → Internal NLB → Istio Gateway → Ollama Pod.
Traffic flow (Web UIs): Client → CloudFront (WAF) → VPC Origin → Internal NLB → Istio Gateway → Open WebUI / Grafana.

CloudFront connects to the internal NLB via **VPC Origins** (private connectivity). This is the core reason for the Gateway API pattern — one internal NLB serves all traffic with path-based HTTPRoutes, and no load balancer is exposed to the internet. All traffic stays on AWS backbone.

### Web UI Authentication (Cognito)

Both Open WebUI and Grafana use **separate Cognito User Pools** with:
- TOTP MFA required on first login
- OAuth/OIDC flow (no local login forms)
- "Request Access" button instead of "Register"
- Admin notification via SNS on new signups
- Role mapping from Cognito groups
- User management exclusively via Cognito Console

| App | Cognito Pool | Roles | CloudFront Path |
|-----|-------------|-------|-----------------|
| Open WebUI | `ollama-webui` | admin, user | `/` (default) |
| Grafana | `ollama-grafana` | admin, viewer | `/grafana/` |

> **TEMPORARY:** In-cluster Grafana + Cognito auth is a stopgap while AMG (AWS Managed Grafana) SSO access is being resolved (Stax ticket pending). Once AMG is accessible: set `enable_grafana = !var.enable_managed_grafana`, remove `grafana_cognito` module + K8s secret + Grafana HTTPRoute, delete `terraform/modules/grafana-cognito/`.

## Default Model: Flagship (qwen3.5:122b-a10b)

The default model is the flagship tier — `qwen3.5:122b-a10b` (MoE, 122B total, 10B active params). Runs on g5.12xlarge (4x A10G, 96GB VRAM).

Three tiers available, all pre-downloaded to EBS via snapshot:

| Tier | Model | GPU | Spot Cost | When to Use |
|------|-------|-----|-----------|-------------|
| 1 (Fallback) | `qwen3.5:27b` | g5.xlarge (1x A10G) | $0.35/hr | Fast iteration, debugging, simple edits |
| 2 (Code) | `qwen3-coder:30b-a3b` | g5.xlarge (1x A10G) | $0.35/hr | Pure coding tasks, very fast MoE inference |
| 3 (Default) | `qwen3.5:122b-a10b` | g5.12xlarge (4x A10G) | $1.90/hr | All tasks — maximum quality, beats GPT-5 mini on tool use (+30%) |

Switch with: `./switch-model.sh use 3` (flagship) or `./switch-model.sh use 1` (fallback).

## Key Design Decisions

- CloudFront + WAF + API Gateway replaces Kong Cloud Gateway — 99% cost reduction ($756/mo → $6/mo), adds DDoS protection, eliminates Transit Gateway dependency
- EKS Auto Mode recommended over manual Karpenter + NVIDIA device plugin — fewer moving parts, AWS manages node lifecycle
- 30-min idle window (`consolidateAfter: 30m`) — nodes stay warm through coffee breaks and short meetings, terminate after 30 min idle
- EBS snapshots for model weights — pre-loaded models on disk, no internet needed for model loading (air-gap compliant), cold start ~3 min instead of 15-25 min
- High-throughput gp3 — 400 MB/s + 6000 IOPS for fast model loading from snapshot
- Self-managed observability — Prometheus + Grafana + DCGM Exporter, all air-gapped (no AMP/AMG)
- Spot with on-demand fallback — Karpenter tries spot first, auto-falls back to on-demand
- Dual-mode pipeline — two separate stacks (deploy one or the other), both maintaining data sovereignty (see below)
- Gateway API pattern with CloudFront VPC Origins — the Istio Gateway creates an internal NLB, and CloudFront connects privately via VPC Origins. This is the core reason for the Gateway API pattern: one internal NLB serves all traffic (Ollama API, Open WebUI, Grafana) with path-based HTTPRoutes, and CloudFront accesses it without exposing any load balancer to the internet
- Cognito authentication for web UIs — Open WebUI and Grafana each have a separate Cognito User Pool with TOTP MFA, OAuth/OIDC, and admin-approved signups. All user management via Cognito Console

## Dual-Mode Pipeline — Two Separate Stacks

Two separate stacks — you deploy one or the other per engagement. Separate stacks ensure compliance by design and eliminate human error risk. The air-gapped stack physically cannot reach Bedrock (no credentials, no egress rules, no API client).

- **Stack A (Fully Air-Gapped):** Phase 1 (analysis) and Phase 2 (report generation) both run on local Ollama/Qwen. Zero external API calls. Best for defence, healthcare, government.
- **Stack B (Hybrid — Local + Bedrock):** Phase 1 always local. Sanitisation layer (regex + LLM review) strips all client data, code, and identifiers. Only sanitised findings JSON goes to the latest Claude Opus model via AWS Bedrock for Phase 2 report generation. Traffic stays on AWS backbone via VPC endpoint. Auth via IAM roles (IRSA), no API keys.

Data flow:
- Stack A: Client Data → Phase 1 (Ollama/Qwen) → Sanitisation → Phase 2 (Ollama/Qwen) → Good quality report
- Stack B: Client Data → Phase 1 (Ollama/Qwen) → Sanitisation → Phase 2 (Latest Claude Opus via Bedrock, sanitised findings only) → High quality report

### Stack B — Bedrock Integration Requirements

Stack B requires additional AWS resources not present in Stack A:

- **VPC Endpoint for Bedrock** — Service: `com.amazonaws.ap-southeast-2.bedrock-runtime`, type: Interface, in private subnets, private DNS enabled. Create in `terraform/modules/bedrock-integration/`.
- **IRSA role for Bedrock access** — Use `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks`. Role name: `ollama-orchestrator-bedrock`. Service account: `orchestrator:orchestrator-sa`. Policy: allow `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on resource `arn:aws:bedrock:${region}::foundation-model/anthropic.claude-*`.
- **NetworkPolicy** — Stack B's orchestrator namespace allows egress to the Bedrock VPC endpoint only. Stack A's orchestrator namespace blocks all egress.
- **Sanitisation layer** — Two-pass: (1) regex strips IPs, emails, API keys, AWS ARNs, JWTs, SSH keys, connection strings; (2) local Qwen reviews sanitised JSON for semantic leakage. Hard stop if raw data detected.

The orchestrator is a separate product built on top of the Ollama-on-EKS infrastructure — separate repo, Dockerfile, and CI.

## Repo Structure

Terraform modules: `terraform/modules/` — vpc, iam, eks, argocd, lb-controller, observability (IMPLEMENTED), api-gateway (IMPLEMENTED, with origin lockdown), cdn-waf (IMPLEMENTED, with origin lockdown), cert-manager (IMPLEMENTED), bedrock-integration (IMPLEMENTED, Stack B only), managed-grafana (IMPLEMENTED, optional — replaces in-cluster Grafana). Each module follows the pattern: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`.

K8s manifests: `k8s/ollama/` — deployment.yaml (pinned to v0.6.2), service.yaml (ClusterIP :11434), networkpolicy.yaml (air-gap enforced). Plus: `k8s/model-loader/`, `k8s/gateway.yaml`, `k8s/httproutes.yaml`, `k8s/monitoring-networkpolicy.yaml` (IMPLEMENTED), `k8s/nodepools/` (IMPLEMENTED — GPU NodePool + EC2NodeClass with EBS snapshot), `k8s/open-webui/` (IMPLEMENTED — browser-based model switching, air-gapped).

ArgoCD: `argocd/apps/` — wave-based Application manifests (waves 00-12, including Open WebUI at wave 7).

Scripts: `scripts/01-setup.sh` through `scripts/06-setup-github-sync.sh`. `scripts/03-setup-cloud-gateway.sh` (DEPRECATED — Kong removed). `scripts/05-generate-certs.sh` (DEPRECATED — replaced by cert-manager). `scripts/create-model-snapshot.sh` (IMPLEMENTED). `scripts/generate-readme-html.py` (IMPLEMENTED).

Workflows: `.github/workflows/kong-sync.yml` (DEPRECATED — Kong removed). `terraform-plan.yml` and `terraform-apply.yml` (IMPLEMENTED).

## Implementation Details by Sprint

### Sprint 1 — Foundation (Week 1, ~4 hrs)

**Gap 1 (Critical): S3 Backend + State Locking.** Risk: `terraform.tfstate` stored locally (111KB), concurrent applies = state corruption. Create `terraform/backend.tf` with S3 backend. Bucket: `ollama-eks-tfstate-<ACCOUNT_ID>`, key: `ollama-eks/terraform.tfstate`, region: `ap-southeast-2`, encrypt: true, DynamoDB table: `ollama-eks-tfstate-lock`. Bootstrap the S3 bucket (with versioning) and DynamoDB table (PAY_PER_REQUEST) before running `terraform init -migrate-state`. Verify with `terraform plan` (should show no changes).

**Gap 2 (Critical): Egress NetworkPolicy.** Risk: Current `k8s/ollama/networkpolicy.yaml` allows egress to `0.0.0.0/0:443`, breaks air-gap. Replace with: name `ollama-airgap` in namespace `ollama`, podSelector `app: ollama`, ingress from `istio-system` namespace on port 11434 TCP only, egress to DNS (port 53 UDP/TCP) only plus intra-cluster (`namespaceSelector: {}`). Verify: `kubectl exec -n ollama deploy/ollama -- curl -s --max-time 5 https://google.com` should timeout.

**Gap 3 (High): Pin Ollama Image.** Change `k8s/ollama/deployment.yaml` from `ollama/ollama:latest` to `ollama/ollama:0.6.2@sha256:<digest>` with `imagePullPolicy: IfNotPresent`. Get digest via `docker inspect`.

**Gap 4 (High): Reconcile NUM_PARALLEL.** Update `k8s/ollama/deployment.yaml` env: `OLLAMA_NUM_PARALLEL: "4"` (was "2", must match TF variable), `OLLAMA_MAX_LOADED_MODELS: "1"`, `OLLAMA_CONTEXT_LENGTH: "32768"`. Remove unused TF variables for Ollama env vars.

### Sprint 2 — EKS Auto Mode + Cost (Week 2, ~8 hrs)

**Gap 7: GPU NodePool + EC2NodeClass.** Create `k8s/nodepools/gpu-nodepool.yaml` — NodePool `gpu-ollama`: instance types g5.xlarge/g5.2xlarge/g5.12xlarge, capacity types spot + on-demand, zones ap-southeast-2a/2b, nodeClassRef to EC2NodeClass `gpu-ollama`, taint `nvidia.com/gpu: NoSchedule`, limits: 48 CPU / 192Gi memory / 4 GPU, disruption: WhenEmpty with `consolidateAfter: 30m`.

Create `k8s/nodepools/gpu-ec2nodeclass.yaml` — EC2NodeClass `gpu-ollama`: AMI alias `al2023@latest`, subnet/SG discovery tags `karpenter.sh/discovery: "ollama-eks"`, two block device mappings: (1) root `/dev/xvda` gp3 50Gi encrypted, (2) data `/dev/xvdb` gp3 200Gi with iops 6000, throughput 400, encrypted, snapshotID from pre-loaded models snapshot. userData mounts `/dev/xvdb` to `/data/ollama` and sets `OLLAMA_MODELS` env var.

**EBS Snapshot Creation.** Create `scripts/create-model-snapshot.sh`: launch temporary g5.xlarge with 200GB gp3 volume (400 MB/s, 6000 IOPS), install Ollama, pull all 3 tiers (`qwen3.5:27b`, `qwen3-coder:30b-a3b`, `qwen3.5:122b-a10b`), stop instance, snapshot data volume, terminate instance. Output the snapshot ID for use in EC2NodeClass.

**EKS Auto Mode.** Enable on cluster — replaces manual Karpenter + NVIDIA device plugin. AWS manages GPU node lifecycle, NVIDIA drivers, and device plugin.

### Sprint 3 — Hardening (Week 3, ~10 hrs)

**CloudFront + WAF + API Gateway.** Create two Terraform modules:

`terraform/modules/api-gateway/` — REST API (v1) with native API key management. Resources: `aws_api_gateway_rest_api`, `aws_api_gateway_vpc_link` (to internal NLB), `aws_api_gateway_resource` + `aws_api_gateway_method` + `aws_api_gateway_integration` (POST /v1/chat/completions + GET /api/tags, HTTP_PROXY via VPC Link), `aws_api_gateway_deployment` + `aws_api_gateway_stage` (prod), `aws_api_gateway_usage_plan` (standard — rate limits + optional quotas), `aws_api_gateway_api_key` (initial key), `aws_api_gateway_method_settings` (throttling + CloudWatch metrics). Variables: `nlb_arn`, `nlb_dns_name`, `api_key_required` (default: true), `throttle_rate`, `throttle_burst`. Outputs: `api_endpoint`, `api_key_id`, `api_key_value` (sensitive), `usage_plan_id`. Keys managed via AWS Console: API Gateway → Usage Plans → API Keys.

`terraform/modules/cdn-waf/` — Resources: `aws_cloudfront_distribution` (origin = API Gateway endpoint, cache disabled for POST, HTTPS only), `aws_wafv2_web_acl` with 5 rules. Variables: `allowed_ips` (CIDR list), `rate_limit` (default 100/5min), `geo_countries` (default ["AU", "US"]). Outputs: `cloudfront_domain`, `waf_arn`.

WAF rules: (1) Rate Limiting — RateBasedRule, 100 requests per 5-minute window per IP. (2) IP Allowlist — IPSetRule, only corporate CIDR ranges. (3) Geo-Blocking — GeoMatchRule, allow AU + US only (configurable). (4) Bot Control — ManagedRuleGroup, AWS Bot Control (optional, ~$10/mo). (5) SQL/XSS — AWSManagedRulesCommonRuleSet.

After implementation, remove: `scripts/03-setup-cloud-gateway.sh`, `.github/workflows/kong-sync.yml`, `deck/` directory, Transit Gateway attachment in `terraform/main.tf`, Kong-related ArgoCD wave applications.

**Gap 6: cert-manager.** Create `terraform/modules/cert-manager/` with Helm release for cert-manager v1.17.1 from `https://charts.jetstack.io`, namespace `cert-manager`, installCRDs enabled. Create `k8s/cert-manager/cluster-issuer.yaml` with self-signed ClusterIssuer and Certificate for `*.ollama.internal` in istio-system namespace (secretName: `istio-gateway-tls`, duration: 90d, renewBefore: 30d). Replaces manual openssl certs.

**Gap 8: Terraform CI/CD.** Create two GitHub Actions workflows: (1) `terraform-plan.yml` — triggers on PR to `terraform/**`, uses OIDC federation (`id-token: write`) with role `arn:aws:iam::role/github-actions-terraform`, runs `terraform plan` and posts output as PR comment via `actions/github-script`. (2) `terraform-apply.yml` — triggers on push to main for `terraform/**`, same OIDC auth, runs `terraform apply -auto-approve`, then `verify-airgap.sh`. Requires GitHub Environment "production" with manual approval. Prerequisites: S3 backend (Gap 1) done first, OIDC federation configured.

### Sprint 4 — Documentation (Week 4, ~8 hrs)

- DATA-SOVEREIGNTY.md — Architecture, network isolation, verification steps, compliance posture
- Update README.md — Replace all Kong references with CloudFront + WAF + API Gateway architecture
- CLIENT-INTEGRATION.md — OpenAI SDK examples, Continue.dev, Open WebUI, curl

### Already Implemented

**Gap 5: Observability** — `terraform/modules/observability/` with Prometheus (kube-prometheus-stack Helm chart), DCGM Exporter (NVIDIA GPU metrics DaemonSet), 6 alert rules (GPU temp > 85°C, GPU memory > 90%, Ollama pod restarts, node not ready, high error rate, PV > 80%). 4 dashboards: GPU metrics, Ollama API metrics, Karpenter node lifecycle, FinOps Showback.

**Origin Lockdown** — CloudFront → API Gateway lockdown via shared secret. CloudFront sends a `Referer` header with a 64-char auto-generated secret; API Gateway resource policy denies requests without a matching `aws:Referer`. Zero additional cost. Toggle: `enable_origin_lockdown` (default: true). Verify: `curl -s https://<api-gw-endpoint>/prod/api/tags` returns 403; requests via CloudFront succeed.

**AWS Managed Grafana (AMG)** — `terraform/modules/managed-grafana/` replaces in-cluster Grafana. Toggle: `enable_managed_grafana` (default: true). Prerequisites: IAM Identity Center enabled. Cost: ~$9-14/mo.

Metrics flow with AMG enabled:
- In-cluster Prometheus scrapes all targets (Ollama, DCGM, kube-state-metrics, node-exporter)
- Prometheus remote-writes to AMP via SigV4 (IRSA role: `ollama-prometheus-amp-write`)
- AMG reads from AMP (IAM role: `ollama-amg-workspace` with `aps:QueryMetrics`)
- AMG reads CloudWatch natively via its IAM role — no pod egress needed, no IRSA for Grafana
- FinOps dashboard uses CloudWatch datasource in AMG (direct IAM access, not via pod)
- NetworkPolicy: Prometheus gets HTTPS egress (port 443) for AMP + STS; no Grafana CloudWatch exception needed
- Dashboard JSON files in `terraform/modules/observability/dashboards/` — import into AMG workspace manually or via API

When `enable_managed_grafana=true`:
- In-cluster Grafana pod disabled (`grafana.enabled: false` in Helm values)
- Grafana IRSA role (CloudWatch) not created — AMG has its own IAM role
- Dashboard ConfigMaps not created — AMG uses its own dashboard storage
- Monitoring NetworkPolicy simplified — single policy, no Grafana-specific exception

## Response Time Expectations

| Scenario | Wait Time |
|----------|-----------|
| Warm node (within 30-min idle window) | 4-6s to first token (flagship) |
| Back from <30 min break | 0s (node still warm) |
| First request of the day / after 30+ min idle | ~3 min cold start, then 4-6s |
| Spot instance reclaimed mid-session | ~2-3 min interruption (auto-recovery) |

Token generation: flagship produces 30-50 tok/s. A 500-token response takes ~10-17s.

## Cost Summary

| Component | Monthly Cost |
|-----------|-------------|
| GPU compute (flagship, 8hrs/day weekdays, spot) | ~$304 |
| 30-min idle window overhead | ~$16 |
| EBS snapshot storage (200GB) | ~$10 |
| gp3 throughput upgrade (400 MB/s) | ~$4 |
| EKS control plane | $73 |
| CloudFront + WAF + API Gateway | ~$6 |
| AWS Managed Grafana + AMP (optional) | ~$9-14 |
| **Total** | **~$413/mo** (or ~$427/mo with AMG) |

Down from $4,155/mo (24/7 on-demand + Kong) — 90% reduction.

## Working Conventions

- Terraform modules follow the pattern: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`
- ArgoCD waves control deployment order — respect wave numbering when adding new resources
- NetworkPolicy is mandatory for any new namespace — default-deny egress, allow only required traffic
- Air-gap principle — no pod should reach the internet unless explicitly justified. Verify with `verify-airgap.sh`
- Branch strategy — create feature branches for each sprint, PR to main with Terraform plan output
- Image tags — always pin to specific version + digest. Never use `:latest`
- Region — `ap-southeast-2` (Sydney) throughout. All resources in this region
- Cluster name — `ollama-eks`
- Naming convention — resources prefixed with `ollama-eks-` or `ollama-` for easy identification

### Provisioning Order (must be followed for all changes)

Changes must respect the layered dependency chain. Never deploy an upper layer before its dependencies:

1. **Cloud Foundations** — VPC, IAM, S3 backend (Terraform)
2. **EKS Cluster** — Control plane, system node group, GPU node pool (Terraform)
3. **Platform Services** — ArgoCD, LB Controller, cert-manager, observability (Terraform)
4. **Edge Security** — API Gateway, CDN-WAF (Terraform — depends on EKS for NLB)
5. **K8s Infrastructure** — CRDs, Istio, NVIDIA plugin (ArgoCD waves -2 to 0)
6. **K8s Platform** — Namespaces, StorageClasses, PVCs (ArgoCD waves 1-2)
7. **Application Workload** — Ollama, Model Loader (ArgoCD waves 3-4)
8. **Networking/Ingress** — Istio Gateway, HTTPRoutes (ArgoCD waves 5-6)
9. **User-Facing Apps** — Open WebUI (ArgoCD wave 7)

When adding new resources, identify which layer they belong to and place them accordingly.

### Documentation Sync (mandatory after every change)

After ANY implementation change (Terraform, K8s, ArgoCD, dashboards, scripts, costs, security), you MUST:

1. Update README.md — affected sections (use the change-type mapping in the `readme-sync` skill)
2. Update relevant Mermaid diagrams (4 total in README.md)
3. Regenerate HTML — `python3 scripts/generate-readme-html.py README.md Ollama-EKS-Report.html`
4. Verify — 4 mermaid blocks, correct table count, no stale references
5. Cross-check CLAUDE.md — ensure consistency with README.md

This is not optional. Documentation drift causes confusion in consulting engagements. The `readme-sync` skill (available as a Cowork plugin and Claude Code project skill) has the full checklist.

### Model Access Control

- Open WebUI model selector is locked for regular users (`MODEL_FILTER_ENABLED: true`)
- Only the default model (`qwen3.5:122b-a10b`) is visible to non-admin users
- Admins (first user + promoted users) can see and switch all tiers
- Cluster-wide model switching is done via `./switch-model.sh use <tier>` by users with kubectl access
- When changing the default model, update BOTH `DEFAULT_MODELS` and `MODEL_FILTER_LIST` in `k8s/open-webui/deployment.yaml`

## Companion Documents

- `Ollama-EKS-Report.html` — Full visual report with 18+ sections, Mermaid diagrams, cost tables (open in browser)
- `RECOMMENDATIONS-Ollama-EKS-Improvements.md` — Detailed recommendations with code snippets for each improvement
- `switch-model.sh` — Model tier switching script (Tier 3 = default)
