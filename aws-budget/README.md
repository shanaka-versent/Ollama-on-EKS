# AWS Cost Protection Stack v2

**9-layer cost protection with auto-discovery circuit breaker for AWS accounts.**

When costs spike beyond a threshold, a Lambda circuit breaker automatically discovers and disables every serverless resource in the account to stop the bleeding.

**Owner:** Shanaka Jayasundera (shanaka.jayasundera@versent.com.au)
**Company:** Versent — Modernisation Practice
**Cost:** < $1/month

---

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                        AWS ACCOUNT (ap-southeast-2)                       │
│                                                                            │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────────────────┐   │
│  │ AWS Budgets  │───►│ SNS: budget- │───►│ Email notification          │   │
│  │ $200/month   │    │ alerts       │    └─────────────────────────────┘   │
│  │ $50/day      │    └──────────────┘                                      │
│  └─────────────┘                                                           │
│                                                                            │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────────────────┐   │
│  │ Cost Anomaly │───►│ SNS: cost-   │───►│ Email notification          │   │
│  │ Detection    │    │ protection-  │    ├─────────────────────────────┤   │
│  └─────────────┘    │ alerts       │───►│ Circuit Breaker Lambda      │   │
│                      │              │    │                             │   │
│  ┌─────────────┐    │              │    │  Auto-discovers & disables: │   │
│  │ CloudWatch   │───►│              │    │  ✓ All Lambda functions     │   │
│  │ Billing      │    │              │    │  ✓ All REST APIs (v1)      │   │
│  │ Alarms       │    │              │    │  ✓ All HTTP APIs (v2)      │   │
│  │ (us-east-1)  │    │              │    │  ✓ All EventBridge rules   │   │
│  │              │    │              │    │  ✓ All Step Functions      │   │
│  │ - Daily $50  │    │              │    │  ✓ All ECS services        │   │
│  │ - Lambda     │    │              │    │  ✓ Tagged EC2 instances    │   │
│  │ - EC2        │    └──────────────┘    │                             │   │
│  │ - NAT GW     │                        │  Exempt: CostProtection=   │   │
│  │ - API GW     │                        │          exempt tag         │   │
│  └─────────────┘                        └─────────────────────────────┘   │
│                                                                            │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────────────────┐   │
│  │ DLQ depth    │───►│ SNS (same)   │───►│ DLQ Watchdog Lambda        │   │
│  │ alarm > 5msg │    │              │    │ Disables specific function  │   │
│  └─────────────┘    └──────────────┘    └─────────────────────────────┘   │
│                                                                            │
│  ┌─────────────┐    ┌─────────────┐                                       │
│  │ GPU node     │───►│ SNS alert   │  (Alert only — manual action)        │
│  │ > 4 hours    │    └─────────────┘                                       │
│  └─────────────┘                                                           │
│                                                                            │
│  ┌─────────────┐    ┌─────────────┐                                       │
│  │ NAT GW      │───►│ SNS alert   │  (Alert only — manual action)        │
│  │ > 5GB/hour   │    └─────────────┘                                       │
│  └─────────────┘                                                           │
└────────────────────────────────────────────────────────────────────────────┘
```

## Protection Layers

| Layer | What It Does | Detection Speed |
|-------|-------------|-----------------|
| 1. AWS Budgets | Monthly budget alerts at 50%, 80%, 100% + forecasted overspend | ~8-12 hours |
| 2. Cost Anomaly Detection | ML-based detection of unusual spending patterns | ~hours |
| 3. CloudWatch Billing Alarms | Daily total + per-service alarms (Lambda, EC2, NAT GW, API GW) — each independently tunable | ~6 hours |
| 4. Circuit Breaker Lambda | Auto-discovers and disables everything — the kill switch | Instant (on trigger) |
| 5. Lambda Concurrency Guards | Per-function concurrency limits | Preventive |
| 6. API Gateway Monitoring | Real-time 5xx error + request spike alarms across ALL APIs (auto-discovers new APIs) | ~5-10 minutes |
| 7. DLQ Watchdog | Auto-disables Lambda functions stuck in failure loops | ~5 minutes |
| 8. GPU Node Monitor | Alerts if GPU node runs longer than configured threshold | Configurable |
| 9. NAT Gateway Monitor | Alerts on data transfer spikes (>5 GB/hour) | 1 hour |

## Tagging Model

| Tag | Value | Behaviour |
|-----|-------|-----------|
| `CostProtection` | `exempt` | Resource is skipped by the circuit breaker |
| `CostProtection` | `enabled` | EC2 instance will be stopped by the circuit breaker |
| (no tag) | — | Lambda, API GW, EventBridge, Step Functions, ECS are disabled by default |

The circuit breaker and DLQ watchdog Lambdas are self-protected — they are never disabled.

## Quick Start

**Prerequisites:** Billing alerts enabled in AWS account, Terraform >= 1.5.0, AWS CLI configured.

```bash
# 1. Clone and configure
cd aws-budget
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# 2. Deploy in DRY RUN mode
terraform init
terraform plan
terraform apply

# 3. Confirm both SNS subscription emails

# 4. Test the circuit breaker (dry run)
aws lambda invoke \
  --function-name cost-circuit-breaker \
  --payload '{"Records":[{"Sns":{"Message":"{\"AlarmName\":\"manual-test\",\"NewStateValue\":\"ALARM\",\"NewStateReason\":\"Manual test\"}"}}]}' \
  --region ap-southeast-2 \
  output.json
cat output.json

# 5. Switch to live mode when ready
# Edit terraform.tfvars: circuit_breaker_dry_run = false
terraform apply
```

## Recovery Procedures

When the circuit breaker fires, follow these steps in order.

### 1. Investigate Root Cause

```bash
# What triggered the alarm?
aws cloudwatch describe-alarm-history \
  --alarm-name "daily-estimated-charges-50usd" \
  --region us-east-1

# Which services are costing money?
aws ce get-cost-and-usage \
  --time-period Start=$(date -d 'yesterday' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY --metrics BlendedCost \
  --group-by Type=DIMENSION,Key=SERVICE

# Check circuit breaker logs
aws logs tail /aws/lambda/cost-circuit-breaker --region ap-southeast-2 --since 1h
```

### 2. Re-enable Lambda Functions

```bash
# Single function
aws lambda delete-function-concurrency --function-name <name> --region ap-southeast-2

# All functions (use with caution)
aws lambda list-functions --region ap-southeast-2 \
  --query 'Functions[].FunctionName' --output text | tr '\t' '\n' | \
  while read fn; do
    echo "Re-enabling: $fn"
    aws lambda delete-function-concurrency --function-name "$fn" --region ap-southeast-2 2>/dev/null
  done
```

### 3. Re-enable API Gateways

```bash
aws apigateway update-stage \
  --rest-api-id <api-id> --stage-name prod \
  --patch-operations \
    op=replace,path='/*/*/throttling/rateLimit',value='10' \
    op=replace,path='/*/*/throttling/burstLimit',value='20' \
  --region ap-southeast-2
```

### 4. Re-enable EventBridge Rules

```bash
aws events enable-rule --name <rule-name> --region ap-southeast-2
```

### 5. Start EC2 Instances

```bash
aws ec2 start-instances --instance-ids <ids> --region ap-southeast-2
```

### 6. Scale Up ECS Services

```bash
aws ecs update-service --cluster <cluster> --service <service> --desired-count <N> --region ap-southeast-2
```

## Adjusting Thresholds

Edit `terraform.tfvars` and run `terraform apply`:

```hcl
monthly_budget_amount = 300   # Increase monthly budget
daily_cost_threshold  = 75    # Increase daily alarm
anomaly_threshold     = 30    # Increase anomaly sensitivity
```

## Stack Cost

| Component | Monthly Cost |
|-----------|-------------|
| AWS Budgets (2 budgets) | Free |
| Cost Anomaly Detection | Free |
| CloudWatch alarms (8 — billing + API GW + GPU + NAT) | ~$0.80 |
| Circuit Breaker Lambda | ~$0.00 |
| DLQ Watchdog Lambda | ~$0.00 |
| SNS notifications | Free |
| **Total** | **< $1/month** |

## Lessons Learned

This stack exists because of real incidents: Lambda runaway loops, budgets that fired too late, alerts at 2am with no auto-response, GPU nodes that Karpenter forgot to scale down, and NAT Gateway data transfer charges from pod pull loops. Every layer addresses a specific failure mode encountered in production.

---

Last updated: March 2026
Author: Shanaka Jayasundera — Versent Modernisation Practice
