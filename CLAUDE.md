# CLAUDE.md — Project Context for Claude Code

This file gives Claude Code the context and requirements to implement changes in this repo.

---

## What This Repo Is

A fully private, air-gapped LLM inference platform on AWS EKS. Ollama serves Qwen 3.5 models on GPU nodes, exposed via CloudFront + WAF + API Gateway. Prompts and source code never leave the AWS account. Designed for consulting engagements where client data sovereignty is non-negotiable.

## Architecture (4 Layers)

Layer 1 — VPC (10.0.0.0/16) with private/public subnets + NAT Gateway.
Layer 2 — EKS Control Plane with Auto Mode enabled. Custom Karpenter NodePools: system pool (t3.xlarge on-demand, x86 only, single AZ `ap-southeast-2a` — fits all system workloads + Open WebUI on one node) + GPU pool (g5 spot, on-demand fallback, flex ceiling allows g5.xlarge and g5.12xlarge, same AZ). Built-in pools disabled (`node_pools = []`). EBS CSI Driver + AWS LB Controller managed by Auto Mode. Single AZ keeps all EBS PVCs co-located; multi-AZ configurable via one-line uncomment in NodePool.
Layer 3 — ArgoCD with wave orchestration (waves -2 to 7). Wave -2: Gateway API CRDs → Wave -1: Istio Base → Wave 0: Istiod + Istio CNI + ztunnel (ambient mesh) → Wave 1: Namespaces + NodePools → Wave 2: Storage + KEDA → Wave 3-4: Ollama + Model Loader + KEDA ScaledObject → Wave 5-6: Gateway + Routes → Wave 7: Open WebUI. NVIDIA device plugin is managed by EKS Auto Mode (NOT deployed via ArgoCD — the ArgoCD app file `05-nvidia-device-plugin.yaml` is intentionally emptied).
Layer 4 — CloudFront (+ WAF + Shield Standard) → API Gateway (REST API, native API key auth) → VPC Link → Internal NLB → Istio Gateway (mTLS) → Ollama Pod.

Traffic flow (API): Client → CloudFront (WAF) → API Gateway (x-api-key) → VPC Link → Internal NLB → Istio Gateway → Ollama Pod.
Traffic flow (Web UI): Client → CloudFront (WAF) → VPC Origin → Internal NLB → Istio Gateway → Open WebUI.

CloudFront connects to the internal NLB via **VPC Origins** (private connectivity). This is the core reason for the Gateway API pattern — one internal NLB serves all traffic with path-based HTTPRoutes, and no load balancer is exposed to the internet. All traffic stays on AWS backbone.

### Web UI Authentication (Cognito)

Open WebUI uses a **Cognito User Pool** with:
- TOTP MFA required on first login
- OAuth/OIDC flow (no local login forms)
- Admin notification via SNS on new signups
- Access-granted notification via SES when user is added to a group
- Role mapping from Cognito groups
- User management exclusively via Cognito Console

| App | Cognito Pool | Roles | CloudFront Path |
|-----|-------------|-------|-----------------|
| Open WebUI | `ollama-webui` | admin, user | `/` (default) |

Grafana is **AWS Managed Grafana (AMG)** — accessed via IAM Identity Center SSO, not through CloudFront.

#### Admin User Flow (Initial Setup)

1. Terraform creates admin user (`cognito_admin_email`) in Cognito pool
2. Admin receives email with temp password for Open WebUI
3. Admin is automatically added to the "admin" group
4. Admin visits CloudFront URL → custom login page loads (`/auth/login.html`)
5. Admin enters email + temp password → portal detects `NEW_PASSWORD_REQUIRED`
6. Admin sets new password → portal detects `MFA_SETUP` → shows QR code
7. Admin scans QR code with authenticator app → enters TOTP code to complete setup
8. Admin can now access Open WebUI (as admin). Grafana access is via AMG SSO (separate URL)

#### New User Flow (Access Request)

1. User visits CloudFront URL → CloudFront Function detects no `token` cookie → redirects to `/auth/login.html` (custom login page)
2. User clicks "Request Access" → fills signup form (name, email, password)
3. Custom portal calls Cognito `SignUp` API directly → account auto-confirmed (Pre Sign-up Lambda)
4. Admin receives SNS email notification with the user's email and instructions
5. Admin goes to AWS Cognito Console → finds user → adds to group ("user"/"viewer" or "admin")
6. User receives "Access Granted" email via SES with login URL and role info
7. User logs in via custom login page → sets up MFA (TOTP via QR code) on first login
8. User can now access the app with role-mapped permissions

**NOTE:** Users **never** see the Cognito hosted UI. All auth flows (login, signup, first-time password change, MFA enrollment, forgot password) are handled by the custom login portal (`auth_proxy` Lambda + `login.html` SPA). The Cognito domain is kept only for server-side OAuth authorization code exchange.

#### Access Control Layers

- **Cognito group membership** = primary gate (managed by admin in AWS Console)
- **ENABLE_OAUTH_ROLE_MANAGEMENT=true** = roles synced from Cognito groups on every login (Cognito is source of truth)
- **OAUTH_ALLOWED_ROLES** = Open WebUI rejects users not in admin/user Cognito groups
- **OAUTH_ADMIN_ROLES** = elevates users in "admin" Cognito group to Open WebUI admin
- **DEFAULT_USER_ROLE=user** = auto-activates OAuth users who pass Cognito group gate
- **ENABLE_PASSWORD_AUTH=false** = hides local password change UI (all password management via Cognito)
- **ENABLE_ADMIN_CHAT_ACCESS=false** = admins cannot view user chats
- **ENABLE_ADMIN_EXPORT=false** = database export disabled

#### Key Implementation Details

- `WEBUI_URL` and `OPENID_REDIRECT_URI` are set dynamically — `CLOUDFRONT_DOMAIN` is stored in the `webui-oauth-cognito` K8s secret (Terraform sets it from `module.cdn_waf.cloudfront_domain`), and both env vars reference it via `$(CLOUDFRONT_DOMAIN)` substitution. No hardcoded CloudFront URLs in deployment YAML
- CloudFront adds `X-Forwarded-Proto: https` as custom origin header (CloudFront uses `CloudFront-Forwarded-Proto`, but uvicorn reads `X-Forwarded-Proto`)
- VPC Origins require `AllViewerExceptHostHeader` origin request policy — `AllViewer` breaks the private NLB connection
- WAF rate limit set to 2000/5min (web UIs load many assets; 100/5min caused false 403s)
- SES email identity must be verified for access-granted notifications to work. If SES is in sandbox mode, recipient emails must also be verified
- Password reset is handled entirely by the custom login portal — user clicks "Forgot password?" on the login page, receives a code via email, then enters the code + new password in the portal. No Cognito hosted UI involved
- `WEBUI_BANNERS` env var is stored in the `webui-oauth-cognito` K8s secret (not hardcoded in deployment YAML) with banner links to `/auth/login.html` for password reset and `/portal/` for API key generation
- Auth proxy Lambda (`auth_proxy.py`) handles 6 endpoints: login, mfa, change-password, setup-mfa, forgot-password, confirm-reset. Login uses a two-phase approach: Phase 1 tries Cognito `InitiateAuth` API directly to detect `NEW_PASSWORD_REQUIRED` and `MFA_SETUP` challenges (first-time users); Phase 2 falls back to Cognito hosted UI scraping for the full OAuth token exchange (returning users with MFA). Forgot password uses Cognito APIs directly (`ForgotPassword`, `ConfirmForgotPassword`). First-time MFA setup uses `AssociateSoftwareToken` → `VerifySoftwareToken` (best-effort `RespondToAuthChallenge(MFA_SETUP)` — non-fatal if it fails, since `VerifySoftwareToken` SUCCESS means the device is registered). Login portal uses a light theme
- Auth proxy Lambda requires IAM permissions for `cognito-idp:InitiateAuth`, `cognito-idp:RespondToAuthChallenge`, `cognito-idp:ForgotPassword`, `cognito-idp:ConfirmForgotPassword`, `cognito-idp:AssociateSoftwareToken`, `cognito-idp:VerifySoftwareToken`
- Cognito `webui` app client has `ALLOW_USER_PASSWORD_AUTH` enabled (required for `InitiateAuth` API used by first-time setup flow)
- CloudFront Function (`auth_redirect`) runs on `viewer-request` event — checks for `token` cookie, redirects unauthenticated users to `/auth/login.html` (custom login page). Excludes: `/oauth/*`, `/_app/*`, `/static/*`, `/api/*`, `/v1/*`, `/portal/*`, `/auth/*`, favicons
- Static assets (`/_app/*`, `/static/*`) use `CachingOptimized` policy at CloudFront edge — eliminates the full CloudFront → NLB → Istio → Pod round-trip for JS/CSS/images, reducing page load from ~10s to <1s

## Default Model: Fallback (qwen3.5:27b) — DEV Phase

**Current phase: DEV** — using Tier 1 fallback (`qwen3.5:27b`) on g5.xlarge (1x A10G, $0.35/hr spot) for infrastructure testing and platform validation. NodePool is restricted to g5.xlarge only — no g5.12xlarge can be provisioned.

**Flex Mode (default):** The DEV NodePool ceiling is raised to ALLOW g5.12xlarge (4x A10G) but defaults to g5.xlarge (1x A10G). `switch-model.sh` patches the Ollama deployment resources — Karpenter auto-provisions the right instance type. Cost stays DEV-level by default; flagship costs more only while actively in use. KEDA + Karpenter handle teardown to $0/hr when idle.

How it works:
1. `./switch-model.sh use 3` → pauses KEDA → patches deployment to 4 GPU/96Gi → Karpenter provisions g5.12xlarge → loads model → resumes KEDA
2. `./switch-model.sh use 1` → pauses KEDA → patches deployment to 1 GPU/14Gi → Karpenter provisions g5.xlarge → loads model → resumes KEDA
3. 15 min idle → KEDA scales to 0 → Karpenter terminates GPU node → $0/hr

ArgoCD Ollama app has `ignoreDifferences` on `/spec/template/spec/containers/0/resources` (in addition to `/spec/replicas`) so `selfHeal` doesn't revert the kubectl patch from `switch-model.sh`.

No separate PROD overlay needed — the same stack handles all tiers via `switch-model.sh`.

**Spot instance strategy:** Spot preferred with on-demand fallback (both DEV and PROD). Karpenter tries spot first — if spot is unavailable (quota pending or no capacity), falls back to on-demand automatically.
- `GPUOnDemandFallback` alert fires (warning) when on-demand is used — so you know you're paying full price.
- `GPUSpotInterruption` alert fires when AWS reclaims a spot instance (warning, expect ~2-3 min interruption).
- Once spot quota is approved, Karpenter will prefer spot automatically — no config change needed.
- **Alert notifications:** Alertmanager → SNS → email. Set `alert_email` in root `terraform/variables.tf` (passed to observability module). SNS subscription confirmation email must be clicked for delivery to work. 8 alert rules: GPU temp, GPU memory (high+critical), pod restarts, pod pending, on-demand fallback, spot interruption, provisioning failed.

Three tiers available, all pre-downloaded to EBS via snapshot:

| Tier | Model | GPU | Spot Cost | When to Use |
|------|-------|-----|-----------|-------------|
| **1 (Current)** | **`qwen3.5:27b`** | **g5.xlarge (1x A10G)** | **$0.35/hr** | **DEV — platform testing, monitoring setup** |
| 2 (Code) | `qwen3-coder:30b-a3b` | g5.xlarge (1x A10G) | $0.35/hr | Pure coding tasks, very fast MoE inference |
| 3 (Flagship) | `qwen3.5:122b-a10b` | g5.12xlarge (4x A10G) | $1.90/hr | PROD — maximum quality |

Switch with: `./switch-model.sh use 3` (flagship, ~5 min) or `./switch-model.sh use 1` (fallback, ~3 min). The script validates NodePool GPU limits, patches deployment resources, pauses KEDA during the switch, and resumes it after. Run `./switch-model.sh status` to see current tier, hardware, and available tiers.

## Key Design Decisions

- CloudFront + WAF + API Gateway replaces Kong Cloud Gateway — 99% cost reduction ($756/mo → $6/mo), adds DDoS protection, eliminates Transit Gateway dependency
- EKS Auto Mode with custom NodePools — Auto Mode manages Karpenter, NVIDIA plugin, EBS CSI, LB controller. Built-in pools disabled (`node_pools = []`). Custom system pool (t3.xlarge on-demand, x86 only, single AZ) and GPU pool (g5 spot with on-demand fallback, flex ceiling allows g5.xlarge + g5.12xlarge, same AZ) give full control over instance types and cost. Single AZ (`ap-southeast-2a`) keeps all EBS PVCs co-located; multi-AZ configurable via one-line uncomment
- System nodes on-demand only — CoreDNS, Istio, Prometheus, ArgoCD cannot tolerate spot interruptions (full cluster outage). GPU nodes use spot (inference tolerates 2-3 min interruptions). `GPUOnDemandFallback` alert fires if GPU falls back to on-demand
- KEDA auto-scale-to-zero — KEDA **only targets the Ollama deployment** (GPU workload). After 15 min of no inference requests, KEDA scales Ollama to 0 replicas. Karpenter then terminates the empty GPU node after 10 min (`consolidateAfter: 10m`). Total idle-to-zero: ~25 min. Scale-from-zero is manual via `scripts/scale-up.sh`. **Open WebUI stays at 1 replica on system nodes (never scaled to zero)** — it runs on t3.xlarge which is always-on. System nodes use 5-min consolidation (`WhenEmptyOrUnderutilized`). ArgoCD Ollama app uses `ignoreDifferences` on `/spec/replicas` and `/spec/template/spec/containers/0/resources` so `selfHeal` doesn't fight KEDA or `switch-model.sh`. KEDA ArgoCD app uses `ServerSideApply=true` to install all CRDs including `scaledjobs.keda.sh`
- Flex mode — DEV NodePool ceiling allows both g5.xlarge and g5.12xlarge. `switch-model.sh` patches Ollama deployment resources via `kubectl patch` and Karpenter auto-provisions the right instance. Default state is Tier 1 (g5.xlarge, DEV cost). Tier 3 flagship costs $1.90/hr spot only while in use. KEDA + Karpenter tear down to $0/hr after 25 min idle regardless of tier
- EKS Auto Mode NodeClass requires explicit `role` field and subnet/SG IDs (tag-based discovery not supported)
- EBS snapshots for model weights — pre-loaded models on disk, no internet needed for model loading (air-gap compliant), cold start ~3 min instead of 15-25 min
- High-throughput gp3 — 400 MB/s + 6000 IOPS for fast model loading from snapshot
- Observability — Prometheus + DCGM Exporter in-cluster, remote-write to AMP; AWS Managed Grafana (AMG) via IAM Identity Center SSO for all dashboards including FinOps
- GPU spot with on-demand fallback — Karpenter tries spot first for GPU nodes, auto-falls back to on-demand
- Dual-mode pipeline — two separate stacks (deploy one or the other), both maintaining data sovereignty (see below)
- Gateway API pattern with CloudFront VPC Origins — the Istio Gateway creates an internal NLB, and CloudFront connects privately via VPC Origins. This is the core reason for the Gateway API pattern: one internal NLB serves all traffic (Ollama API, Open WebUI) with path-based HTTPRoutes, and CloudFront accesses it without exposing any load balancer to the internet
- Cognito authentication for Open WebUI — Cognito User Pool with TOTP MFA, OAuth/OIDC, and admin-approved signups. All user management via Cognito Console. Grafana auth is via AMG SSO (IAM Identity Center)
- Single-stack flex architecture — One set of K8s manifests, no overlays. `switch-model.sh` patches deployment resources at runtime. ArgoCD apps point directly to base manifests (`k8s/ollama/`, `k8s/nodepools/`, etc.). ArgoCD `ignoreDifferences` on container resources prevents selfHeal from reverting patches. Terraform tfvars in `terraform/environments/` for cloud-level config.

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

Terraform modules: `terraform/modules/` — vpc, iam, eks, argocd, lb-controller, observability (IMPLEMENTED), api-gateway (IMPLEMENTED, with origin lockdown), cdn-waf (IMPLEMENTED, with origin lockdown), cert-manager (IMPLEMENTED), bedrock-integration (IMPLEMENTED, Stack B only), managed-grafana (IMPLEMENTED — AMG + AMP, SSO via IAM Identity Center), cognito (IMPLEMENTED — Open WebUI Cognito User Pool + OAuth/OIDC), api-key-portal (IMPLEMENTED — self-service API key management with Cognito auth). Each module follows the pattern: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`.

Terraform environments: `terraform/environments/` — per-environment tfvars (dev.tfvars, prod.tfvars).

K8s manifests: `k8s/ollama/` — deployment.yaml (pinned to v0.18.2), service.yaml (ClusterIP :11434), networkpolicy.yaml (air-gap enforced). Plus: `k8s/model-loader/`, `k8s/gateway.yaml`, `k8s/httproutes.yaml`, `k8s/monitoring-networkpolicy.yaml` (IMPLEMENTED), `k8s/nodepools/` (IMPLEMENTED — system NodePool `t3.xlarge on-demand` + GPU NodePool `g5 spot` + NodeClasses for both, all `karpenter.sh/v1` + `eks.amazonaws.com/v1` APIs), `k8s/keda/` (IMPLEMENTED — KEDA ScaledObject for auto-scale-to-zero after 15 min idle), `k8s/open-webui/` (IMPLEMENTED — Cognito auth, model locked to admins), `k8s/cert-manager/`, `k8s/namespaces.yaml`.

ArgoCD: `argocd/apps/` — wave-based Application manifests (files 00-12 + 01b, 02b, 04b; waves -2 to 7). Wave -2: Gateway API CRDs, Wave -1: Istio Base, Wave 0: Istiod + CNI + ztunnel, Wave 1: Namespaces + NodePools, Wave 2: Storage + KEDA, Wave 3: Ollama, Wave 4: Model Loader + KEDA ScaledObject, Wave 5: Gateway, Wave 6: HTTPRoutes, Wave 7: Open WebUI. File `05-nvidia-device-plugin.yaml` is intentionally emptied (comments only) — EKS Auto Mode manages NVIDIA plugin. ArgoCD apps point directly to base manifests (no overlays) — `switch-model.sh` handles runtime tier switching via kubectl patch.

Scripts: `scripts/01-setup.sh`, `scripts/04-post-setup.sh`, `scripts/06-setup-github-sync.sh`, `scripts/create-model-snapshot.sh` (IMPLEMENTED), `scripts/generate-readme-html.py` (IMPLEMENTED), `scripts/deploy-stack-a.sh` (Stack A deployment), `scripts/scale-up.sh` / `scripts/scale-down.sh` (UPDATED — Karpenter-native, pauses/unpauses KEDA, no managed node group ops), `scripts/setup-amg.sh` (IMPLEMENTED — AMG data source + dashboard setup, run once after first deploy), `scripts/test-ollama-stack.sh` (end-to-end stack test), `scripts/verify-airgap.sh` (air-gap compliance check). Removed: `03-setup-cloud-gateway.sh` (Kong), `05-generate-certs.sh` (replaced by cert-manager).

Workflows: `.github/workflows/terraform-plan.yml` and `terraform-apply.yml` (IMPLEMENTED). Kong workflow removed.

## Implementation Details by Sprint

### Sprint 1 — Foundation (Week 1, ~4 hrs)

**Gap 1 (Critical): S3 Backend + State Locking.** Risk: `terraform.tfstate` stored locally (111KB), concurrent applies = state corruption. Create `terraform/backend.tf` with S3 backend. Bucket: `ollama-eks-tfstate-<ACCOUNT_ID>`, key: `ollama-eks/terraform.tfstate`, region: `ap-southeast-2`, encrypt: true, DynamoDB table: `ollama-eks-tfstate-lock`. Bootstrap the S3 bucket (with versioning) and DynamoDB table (PAY_PER_REQUEST) before running `terraform init -migrate-state`. Verify with `terraform plan` (should show no changes).

**Gap 2 (Critical): Egress NetworkPolicy.** Risk: Current `k8s/ollama/networkpolicy.yaml` allows egress to `0.0.0.0/0:443`, breaks air-gap. Replace with: name `ollama-airgap` in namespace `ollama`, podSelector `app: ollama`, ingress from `istio-system` namespace on port 11434 TCP only, egress to DNS (port 53 UDP/TCP) only plus intra-cluster (`namespaceSelector: {}`). Verify: `kubectl exec -n ollama deploy/ollama -- curl -s --max-time 5 https://google.com` should timeout.

**Gap 3 (High): Pin Ollama Image.** Change `k8s/ollama/deployment.yaml` from `ollama/ollama:latest` to `ollama/ollama:0.6.2@sha256:<digest>` with `imagePullPolicy: IfNotPresent`. Get digest via `docker inspect`.

**Gap 4 (High): Reconcile NUM_PARALLEL.** Update `k8s/ollama/deployment.yaml` env: `OLLAMA_NUM_PARALLEL: "4"` (was "2", must match TF variable), `OLLAMA_MAX_LOADED_MODELS: "1"`, `OLLAMA_CONTEXT_LENGTH: "32768"`. Remove unused TF variables for Ollama env vars.

### Sprint 2 — EKS Auto Mode + Cost (Week 2, ~8 hrs)

**Gap 7: GPU NodePool + NodeClass (EKS Auto Mode).** CRITICAL: EKS Auto Mode uses different APIs than standalone Karpenter.

- **NodePool** (`karpenter.sh/v1`, NOT v1beta1): `k8s/nodepools/gpu-nodepool.yaml` — NodePool `gpu-ollama` with `eks.amazonaws.com` instance selectors (instance-category: g, instance-family: g5, instance-size: xlarge/2xlarge/12xlarge), `karpenter.sh/capacity-type: spot + on-demand` (spot preferred), NVIDIA GPU manufacturer filter, zones ap-southeast-2a/2b, taint `nvidia.com/gpu: NoSchedule`, limits: 48 CPU / 192Gi / 4 GPU, disruption: `WhenEmpty` with `consolidateAfter: 30m`, `expireAfter: 336h`, `budgets: nodes 100%`.

- **NodeClass** (`eks.amazonaws.com/v1`, NOT karpenter.k8s.aws EC2NodeClass): `k8s/nodepools/gpu-nodeclass.yaml` — NodeClass `gpu-ollama` with subnet/SG discovery tags `karpenter.sh/discovery: "ollama-eks"`, ephemeralStorage: 80Gi with 6000 IOPS and 400 MB/s throughput.

- **nodeClassRef format**: `group: eks.amazonaws.com`, `kind: NodeClass`, `name: gpu-ollama` (NOT the old `nodeClassRef: name: gpu-ollama` shorthand).

**EBS Snapshot for Models.** Pre-loaded model weights are attached via PersistentVolume backed by EBS snapshot, NOT via NodeClass blockDeviceMappings (EKS Auto Mode NodeClass doesn't support blockDeviceMappings). Script: `scripts/create-model-snapshot.sh`.

**EKS Auto Mode.** Enabled on cluster — AWS manages Karpenter, NVIDIA device plugin, EBS CSI, and LB controller. The `compute_config.node_pools` in Terraform should include `["general-purpose", "system"]` for built-in pools; custom GPU NodePool is applied separately via ArgoCD.

### Sprint 3 — Hardening (Week 3, ~10 hrs)

**CloudFront + WAF + API Gateway.** Create two Terraform modules:

`terraform/modules/api-gateway/` — REST API (v1) with native API key management. Resources: `aws_api_gateway_rest_api`, `aws_api_gateway_vpc_link` (to internal NLB), `aws_api_gateway_resource` + `aws_api_gateway_method` + `aws_api_gateway_integration` (POST /v1/chat/completions + GET /api/tags, HTTP_PROXY via VPC Link), `aws_api_gateway_deployment` + `aws_api_gateway_stage` (prod), `aws_api_gateway_usage_plan` (standard — rate limits + optional quotas), `aws_api_gateway_api_key` (initial key), `aws_api_gateway_method_settings` (throttling + CloudWatch metrics). Variables: `nlb_arn`, `nlb_dns_name`, `api_key_required` (default: true), `throttle_rate`, `throttle_burst`. Outputs: `api_endpoint`, `api_key_id`, `api_key_value` (sensitive), `usage_plan_id`. Keys managed via AWS Console: API Gateway → Usage Plans → API Keys.

`terraform/modules/cdn-waf/` — Resources: `aws_cloudfront_distribution` (origin = API Gateway endpoint, cache disabled for POST, HTTPS only), `aws_wafv2_web_acl` with 5 rules. Variables: `allowed_ips` (CIDR list), `rate_limit` (default 100/5min), `geo_countries` (default ["AU", "US"]). Outputs: `cloudfront_domain`, `waf_arn`.

WAF rules: (1) Rate Limiting — RateBasedRule, 100 requests per 5-minute window per IP. (2) IP Allowlist — IPSetRule, only corporate CIDR ranges. (3) Geo-Blocking — GeoMatchRule, allow AU + US only (configurable). (4) Bot Control — ManagedRuleGroup, AWS Bot Control (optional, ~$10/mo). (5) SQL/XSS — AWSManagedRulesCommonRuleSet.

Kong cleanup completed: removed `scripts/03-setup-cloud-gateway.sh`, `.github/workflows/kong-sync.yml`, `deck/` directory, Transit Gateway attachment, Kong-related ArgoCD wave applications.

**Gap 6: cert-manager.** Create `terraform/modules/cert-manager/` with Helm release for cert-manager v1.17.1 from `https://charts.jetstack.io`, namespace `cert-manager`, installCRDs enabled. Create `k8s/cert-manager/cluster-issuer.yaml` with self-signed ClusterIssuer and Certificate for `*.ollama.internal` in istio-system namespace (secretName: `istio-gateway-tls`, duration: 90d, renewBefore: 30d). Replaces manual openssl certs.

**Gap 8: Terraform CI/CD.** Create two GitHub Actions workflows: (1) `terraform-plan.yml` — triggers on PR to `terraform/**`, uses OIDC federation (`id-token: write`) with role `arn:aws:iam::role/github-actions-terraform`, runs `terraform plan` and posts output as PR comment via `actions/github-script`. (2) `terraform-apply.yml` — triggers on push to main for `terraform/**`, same OIDC auth, runs `terraform apply -auto-approve`, then `verify-airgap.sh`. Requires GitHub Environment "production" with manual approval. Prerequisites: S3 backend (Gap 1) done first, OIDC federation configured.

### Sprint 4 — Documentation (Week 4, ~8 hrs)

- DATA-SOVEREIGNTY.md — Architecture, network isolation, verification steps, compliance posture
- Update README.md — Replace all Kong references with CloudFront + WAF + API Gateway architecture
- CLIENT-INTEGRATION.md — OpenAI SDK examples, Continue.dev, Open WebUI, curl

### Already Implemented

**Gap 5: Observability** — `terraform/modules/observability/` with Prometheus (kube-prometheus-stack Helm chart), DCGM Exporter (NVIDIA GPU metrics DaemonSet, 256Mi/512Mi memory), 8 alert rules (GPU temp, GPU memory high+critical, pod restarts, pod pending, on-demand fallback, spot interruption, provisioning failed), Alertmanager → SNS → email notifications. 4 dashboards: GPU metrics, Ollama API metrics, Karpenter node lifecycle, FinOps Showback. AMG data sources and dashboards configured via `scripts/setup-amg.sh` (run once after first deploy). **Note:** EKS Auto Mode runs Karpenter on the control plane — native `karpenter_*` metrics are unavailable. The Karpenter dashboard uses `kube-state-metrics` (`kube_node_status_capacity`, `kube_deployment_spec_replicas`) to track GPU node scaling and KEDA events.

**Origin Lockdown** — CloudFront → API Gateway lockdown via shared secret. CloudFront sends a `Referer` header with a 64-char auto-generated secret; API Gateway resource policy denies requests without a matching `aws:Referer`. Zero additional cost. Toggle: `enable_origin_lockdown` (default: true). Verify: `curl -s https://<api-gw-endpoint>/prod/api/tags` returns 403; requests via CloudFront succeed.

**AWS Managed Grafana (AMG)** — `terraform/modules/managed-grafana/` provides all dashboard access via IAM Identity Center SSO. No in-cluster Grafana. Prerequisites: IAM Identity Center enabled. Cost: ~$9-14/mo.

Metrics flow:
- In-cluster Prometheus scrapes all targets (Ollama, DCGM, kube-state-metrics, node-exporter)
- Prometheus remote-writes to AMP via SigV4 (IRSA role: `ollama-prometheus-amp-write`)
- AMG reads from AMP (IAM role: `ollama-amg-workspace` with `aps:QueryMetrics`)
- AMG reads CloudWatch natively via its IAM role — FinOps dashboard uses CloudWatch datasource
- No pod egress needed for Grafana, no IRSA for Grafana, no Grafana-specific NetworkPolicy exception
- Dashboard JSON files in `terraform/modules/observability/dashboards/` — import into AMG via `scripts/setup-amg.sh` (creates service account, configures AMP + CloudWatch data sources, imports all 4 dashboards)

## AWS Account Prerequisites

Before deploying GPU workloads, ensure these Service Quotas are increased (default is 0 for GPU instances in most accounts):

| Quota | Code | Minimum Required | Recommended |
|-------|------|-----------------|-------------|
| All G and VT Spot Instance Requests | `L-3819A6DF` | 48 vCPUs | 64 vCPUs |
| Running On-Demand G and VT instances | `L-DB2E81BA` | 48 vCPUs | 64 vCPUs |

A g5.12xlarge (flagship tier) requires 48 vCPUs. Without these quotas, Karpenter will silently fail to provision GPU nodes. Request increases via AWS CLI or Service Quotas console — approval takes 1-3 business days for ap-southeast-2.

## Response Time Expectations

| Scenario | Wait Time |
|----------|-----------|
| Warm node (active within 15-min KEDA window) | 4-6s to first token (flagship) |
| Back from <15 min break | 0s (pod still running) |
| First request of the day / after 25+ min idle | ~3 min cold start (KEDA scaled to 0 at 15 min, Karpenter terminated node at 25 min), then 4-6s |
| Spot instance reclaimed mid-session | ~2-3 min interruption (auto-recovery) |

Token generation: flagship produces 30-50 tok/s. A 500-token response takes ~10-17s.

## Cost Summary

### Idle Cluster (no GPU, system nodes only)

| Component | Monthly Cost |
|-----------|-------------|
| System nodes (1x t3.xlarge on-demand, always-on) | ~$122 |
| EKS control plane | $73 |
| CloudFront + WAF + API Gateway | ~$6 |
| AWS Managed Grafana + AMP | ~$9-14 |
| **Total (idle)** | **~$214/mo** |

### DEV Phase (current — Tier 1 fallback, g5.2xlarge spot)

| Component | Monthly Cost |
|-----------|-------------|
| System nodes (1x t3.xlarge on-demand) | ~$122 |
| GPU compute (fallback, 8hrs/day weekdays, spot) | ~$56 |
| KEDA idle overhead (~25 min to full shutdown) | ~$2 |
| EBS storage (200GB gp3) | ~$14 |
| EKS control plane | $73 |
| CloudFront + WAF + API Gateway | ~$6 |
| AWS Managed Grafana + AMP | ~$9-14 |
| **Total (DEV)** | **~$288/mo** |

### PROD Phase (Tier 3 flagship, g5.12xlarge spot)

| Component | Monthly Cost |
|-----------|-------------|
| System nodes (1-2x t3.xlarge on-demand) | ~$122-244 |
| GPU compute (flagship, 8hrs/day weekdays, spot) | ~$304 |
| KEDA idle overhead (~25 min to full shutdown) | ~$11 |
| EBS storage (200GB gp3) | ~$14 |
| EKS control plane | $73 |
| CloudFront + WAF + API Gateway | ~$6 |
| AWS Managed Grafana + AMP | ~$9-14 |
| **Total (PROD)** | **~$548/mo** |

Down from $4,155/mo (24/7 on-demand + Kong) — 90%+ reduction.

## Working Conventions

- Terraform modules follow the pattern: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`
- ArgoCD waves control deployment order — respect wave numbering when adding new resources
- NetworkPolicy is mandatory for any new namespace — default-deny egress, allow only required traffic
- Air-gap principle — no pod should reach the internet unless explicitly justified. Verify with `verify-airgap.sh`
- Branch strategy — create feature branches for each sprint, PR to main with Terraform plan output
- Image tags — always pin to specific version + digest. Never use `:latest`
- Region — `ap-southeast-2` (Sydney) throughout. All resources in this region
- Cluster name — `eks-ollama-dev`
- Naming convention — resources prefixed with `ollama-eks-` or `ollama-` for easy identification
- Model tier switching — use `./switch-model.sh use <tier>` to switch between Tier 1/2/3. The script patches deployment resources via kubectl, Karpenter auto-provisions the right instance. No file editing needed

### Provisioning Order (must be followed for all changes)

Changes must respect the layered dependency chain. Never deploy an upper layer before its dependencies:

1. **Cloud Foundations** — VPC, IAM, S3 backend (Terraform)
2. **EKS Cluster** — Control plane with Auto Mode, custom NodePools (system + GPU) via ArgoCD (Terraform)
3. **Platform Services** — ArgoCD, LB Controller, cert-manager, observability (Terraform)
4. **Edge Security** — API Gateway, CDN-WAF (Terraform — depends on EKS for NLB)
5. **K8s Infrastructure** — Gateway API CRDs, Istio (base, istiod, CNI, ztunnel) (ArgoCD waves -2 to 0). NVIDIA device plugin is NOT deployed here — managed by EKS Auto Mode
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
- Only the default model is visible to non-admin users (`qwen3.5:27b` on fresh deploy)
- Admins (first user + promoted users) can see and switch all tiers
- Cluster-wide model switching is done via `./switch-model.sh use <tier>` by users with kubectl access
- To change the default model shown to users, update `DEFAULT_MODELS` and `MODEL_FILTER_LIST` in `k8s/open-webui/deployment.yaml`

## Companion Documents

- `Ollama-EKS-Report.html` — Full visual report with 18+ sections, Mermaid diagrams, cost tables (open in browser)
- `RECOMMENDATIONS-Ollama-EKS-Improvements.md` — Detailed recommendations with code snippets for each improvement
- `switch-model.sh` — Flex mode model tier switching script (patches deployment resources, Karpenter auto-provisions the right GPU instance)
