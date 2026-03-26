"""
AWS Cost Circuit Breaker — Auto-Discovery Kill Switch
@author Shanaka Jayasundera - shanaka.jayasundera@versent.com.au

When triggered by a CloudWatch billing alarm or cost anomaly detection via SNS,
this Lambda auto-discovers and disables every serverless resource in the account.

Resource types discovered and disabled:
  - Lambda functions → sets ReservedConcurrentExecutions = 0
  - REST API Gateways (v1) → throttles all stages to 0 req/s
  - HTTP API Gateways (v2) → throttles all stages to 0 req/s
  - EventBridge rules → disables all enabled rules
  - Step Functions → stops all running executions
  - ECS services → scales desired count to 0
  - EC2 instances (tagged CostProtection=enabled) → stops them

Exemption: Resources tagged with CostProtection=exempt are skipped.
Self-protection: This Lambda and the DLQ watchdog are always exempt.

Environment variables:
  DRY_RUN              - "true" to log actions without executing (default: true)
  SNS_TOPIC_ARN        - SNS topic for sending detailed results notification
  SELF_FUNCTION_NAME   - This Lambda's function name (auto-exempt)
  WATCHDOG_FUNCTION_NAME - DLQ watchdog Lambda name (auto-exempt)
  AWS_ACCOUNT_ID       - Account ID for logging
"""

import json
import os
import logging
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

DRY_RUN = os.environ.get("DRY_RUN", "true").lower() == "true"
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
SELF_FUNCTION_NAME = os.environ.get("SELF_FUNCTION_NAME", "cost-circuit-breaker")
WATCHDOG_FUNCTION_NAME = os.environ.get("WATCHDOG_FUNCTION_NAME", "cost-dlq-watchdog")
EXEMPT_TAG_KEY = "CostProtection"
EXEMPT_TAG_VALUE = "exempt"
EC2_ENABLE_TAG_VALUE = "enabled"

# Parse exempt lists from environment (JSON arrays set by Terraform)
def _parse_json_env(key, default=None):
    """Parse a JSON-encoded environment variable into a Python object."""
    raw = os.environ.get(key, "")
    if not raw:
        return default or []
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        logger.warning(f"Could not parse {key} env var: {raw[:100]}")
        return default or []

# Self-protected function names — never disabled regardless of tags
# Includes Terraform-managed exempt list (e.g., auth Lambdas, Cognito triggers)
EXEMPT_LAMBDAS = set(_parse_json_env("EXEMPT_LAMBDAS")) | {SELF_FUNCTION_NAME, WATCHDOG_FUNCTION_NAME}
EXEMPT_API_GW_IDS = set(_parse_json_env("EXEMPT_API_GW_IDS"))


def handler(event, context):
    """Main Lambda handler — triggered by SNS from CloudWatch/Cost Anomaly."""
    logger.info(f"Circuit breaker triggered. DRY_RUN={DRY_RUN}")
    logger.info(f"Event: {json.dumps(event, default=str)}")

    trigger_reason = _extract_trigger_reason(event)
    logger.info(f"Trigger reason: {trigger_reason}")

    results = {
        "trigger": trigger_reason,
        "dry_run": DRY_RUN,
        "lambda": disable_lambda_functions(),
        "rest_api": disable_rest_apis(),
        "http_api": disable_http_apis(),
        "eventbridge": disable_eventbridge_rules(),
        "step_functions": stop_step_functions(),
        "ecs": scale_down_ecs_services(),
        "ec2": stop_tagged_ec2_instances(),
    }

    summary = _build_summary(results)
    logger.info(f"Circuit breaker summary:\n{summary}")

    if SNS_TOPIC_ARN:
        _send_sns_notification(summary, results)

    return {
        "statusCode": 200,
        "body": json.dumps(results, default=str),
    }


def _extract_trigger_reason(event):
    """Extract the alarm name / reason from the SNS event."""
    try:
        for record in event.get("Records", []):
            sns_msg = record.get("Sns", {}).get("Message", "")
            try:
                msg = json.loads(sns_msg)
                alarm = msg.get("AlarmName", "unknown")
                reason = msg.get("NewStateReason", "No reason provided")
                return f"{alarm}: {reason}"
            except (json.JSONDecodeError, TypeError):
                return sns_msg[:200] if sns_msg else "Unknown trigger"
    except Exception:
        pass
    return "Unknown trigger (could not parse event)"


def _is_exempt(tags_dict):
    """Check if a resource is exempt via CostProtection=exempt tag."""
    return tags_dict.get(EXEMPT_TAG_KEY, "").lower() == EXEMPT_TAG_VALUE


# ==========================================================================
# LAMBDA FUNCTIONS
# ==========================================================================

def disable_lambda_functions():
    """Discover all Lambda functions and set concurrency to 0."""
    client = boto3.client("lambda")
    results = {"discovered": 0, "disabled": 0, "exempt": 0, "errors": [], "details": []}

    try:
        paginator = client.get_paginator("list_functions")
        for page in paginator.paginate():
            for fn in page.get("Functions", []):
                fn_name = fn["FunctionName"]
                results["discovered"] += 1

                # Exempt check — self-protected + Terraform-managed exempt list
                if fn_name in EXEMPT_LAMBDAS:
                    results["exempt"] += 1
                    results["details"].append(f"EXEMPT (protected): {fn_name}")
                    continue

                # Check tags for exemption
                try:
                    tags = client.list_tags(Resource=fn["FunctionArn"]).get("Tags", {})
                    if _is_exempt(tags):
                        results["exempt"] += 1
                        results["details"].append(f"EXEMPT (tagged): {fn_name}")
                        continue
                except ClientError:
                    pass

                # Disable by setting concurrency to 0
                if DRY_RUN:
                    results["details"].append(f"[DRY RUN] Would disable: {fn_name}")
                    results["disabled"] += 1
                else:
                    try:
                        client.put_function_concurrency(
                            FunctionName=fn_name,
                            ReservedConcurrentExecutions=0,
                        )
                        results["details"].append(f"DISABLED: {fn_name}")
                        results["disabled"] += 1
                    except ClientError as e:
                        results["errors"].append(f"{fn_name}: {e}")
    except ClientError as e:
        results["errors"].append(f"ListFunctions failed: {e}")

    logger.info(f"Lambda: {results['discovered']} found, {results['disabled']} disabled, {results['exempt']} exempt")
    return results


# ==========================================================================
# REST API GATEWAYS (v1)
# ==========================================================================

def disable_rest_apis():
    """Discover all REST API Gateways and throttle all stages to 0 req/s."""
    client = boto3.client("apigateway")
    results = {"discovered": 0, "disabled": 0, "exempt": 0, "errors": [], "details": []}

    try:
        apis = client.get_rest_apis(limit=500).get("items", [])
        for api in apis:
            api_id = api["id"]
            api_name = api.get("name", api_id)
            results["discovered"] += 1

            # Check explicit ID exemption (Terraform-managed) or tag exemption
            tags = api.get("tags", {})
            if api_id in EXEMPT_API_GW_IDS or _is_exempt(tags):
                results["exempt"] += 1
                results["details"].append(f"EXEMPT: {api_name} ({api_id})")
                continue

            # Get all stages
            try:
                stages = client.get_stages(restApiId=api_id).get("item", [])
                for stage in stages:
                    stage_name = stage["stageName"]
                    if DRY_RUN:
                        results["details"].append(
                            f"[DRY RUN] Would throttle: {api_name}/{stage_name}"
                        )
                    else:
                        try:
                            client.update_stage(
                                restApiId=api_id,
                                stageName=stage_name,
                                patchOperations=[
                                    {
                                        "op": "replace",
                                        "path": "/*/*/throttling/rateLimit",
                                        "value": "0",
                                    },
                                    {
                                        "op": "replace",
                                        "path": "/*/*/throttling/burstLimit",
                                        "value": "0",
                                    },
                                ],
                            )
                            results["details"].append(
                                f"THROTTLED: {api_name}/{stage_name}"
                            )
                        except ClientError as e:
                            results["errors"].append(
                                f"{api_name}/{stage_name}: {e}"
                            )
                results["disabled"] += 1
            except ClientError as e:
                results["errors"].append(f"{api_name} stages: {e}")
    except ClientError as e:
        results["errors"].append(f"GetRestApis failed: {e}")

    logger.info(f"REST APIs: {results['discovered']} found, {results['disabled']} disabled")
    return results


# ==========================================================================
# HTTP API GATEWAYS (v2)
# ==========================================================================

def disable_http_apis():
    """Discover all HTTP API Gateways (v2) and throttle stages to 0."""
    client = boto3.client("apigatewayv2")
    results = {"discovered": 0, "disabled": 0, "exempt": 0, "errors": [], "details": []}

    try:
        apis = client.get_apis().get("Items", [])
        for api in apis:
            api_id = api["ApiId"]
            api_name = api.get("Name", api_id)
            results["discovered"] += 1

            tags = api.get("Tags", {})
            if _is_exempt(tags):
                results["exempt"] += 1
                results["details"].append(f"EXEMPT: {api_name} ({api_id})")
                continue

            try:
                stages = client.get_stages(ApiId=api_id).get("Items", [])
                for stage in stages:
                    stage_name = stage["StageName"]
                    if DRY_RUN:
                        results["details"].append(
                            f"[DRY RUN] Would throttle: {api_name}/{stage_name}"
                        )
                    else:
                        try:
                            client.update_stage(
                                ApiId=api_id,
                                StageName=stage_name,
                                DefaultRouteSettings={
                                    "ThrottlingBurstLimit": 0,
                                    "ThrottlingRateLimit": 0.0,
                                },
                            )
                            results["details"].append(
                                f"THROTTLED: {api_name}/{stage_name}"
                            )
                        except ClientError as e:
                            results["errors"].append(
                                f"{api_name}/{stage_name}: {e}"
                            )
                results["disabled"] += 1
            except ClientError as e:
                results["errors"].append(f"{api_name} stages: {e}")
    except ClientError as e:
        results["errors"].append(f"GetApis failed: {e}")

    logger.info(f"HTTP APIs: {results['discovered']} found, {results['disabled']} disabled")
    return results


# ==========================================================================
# EVENTBRIDGE RULES
# ==========================================================================

def disable_eventbridge_rules():
    """Discover all EventBridge rules and disable them."""
    client = boto3.client("events")
    results = {"discovered": 0, "disabled": 0, "exempt": 0, "errors": [], "details": []}

    try:
        paginator = client.get_paginator("list_rules")
        for page in paginator.paginate():
            for rule in page.get("Rules", []):
                rule_name = rule["Name"]
                rule_arn = rule["Arn"]
                results["discovered"] += 1

                if rule["State"] == "DISABLED":
                    results["details"].append(f"ALREADY DISABLED: {rule_name}")
                    continue

                # Check tags
                try:
                    tags_resp = client.list_tags_for_resource(ResourceARN=rule_arn)
                    tags = {t["Key"]: t["Value"] for t in tags_resp.get("Tags", [])}
                    if _is_exempt(tags):
                        results["exempt"] += 1
                        results["details"].append(f"EXEMPT: {rule_name}")
                        continue
                except ClientError:
                    pass

                if DRY_RUN:
                    results["details"].append(f"[DRY RUN] Would disable: {rule_name}")
                    results["disabled"] += 1
                else:
                    try:
                        client.disable_rule(Name=rule_name)
                        results["details"].append(f"DISABLED: {rule_name}")
                        results["disabled"] += 1
                    except ClientError as e:
                        results["errors"].append(f"{rule_name}: {e}")
    except ClientError as e:
        results["errors"].append(f"ListRules failed: {e}")

    logger.info(f"EventBridge: {results['discovered']} found, {results['disabled']} disabled")
    return results


# ==========================================================================
# STEP FUNCTIONS
# ==========================================================================

def stop_step_functions():
    """Discover all Step Functions and stop running executions."""
    client = boto3.client("stepfunctions")
    results = {"discovered": 0, "stopped": 0, "exempt": 0, "errors": [], "details": []}

    try:
        paginator = client.get_paginator("list_state_machines")
        for page in paginator.paginate():
            for sm in page.get("stateMachines", []):
                sm_arn = sm["stateMachineArn"]
                sm_name = sm["name"]
                results["discovered"] += 1

                # Check tags
                try:
                    tags_resp = client.list_tags_for_resource(resourceArn=sm_arn)
                    tags = {t["key"]: t["value"] for t in tags_resp.get("tags", [])}
                    if _is_exempt(tags):
                        results["exempt"] += 1
                        results["details"].append(f"EXEMPT: {sm_name}")
                        continue
                except ClientError:
                    pass

                # Stop all running executions
                try:
                    exec_paginator = client.get_paginator("list_executions")
                    for exec_page in exec_paginator.paginate(
                        stateMachineArn=sm_arn, statusFilter="RUNNING"
                    ):
                        for execution in exec_page.get("executions", []):
                            exec_arn = execution["executionArn"]
                            if DRY_RUN:
                                results["details"].append(
                                    f"[DRY RUN] Would stop: {sm_name}/{execution['name']}"
                                )
                            else:
                                try:
                                    client.stop_execution(
                                        executionArn=exec_arn,
                                        cause="Cost circuit breaker triggered",
                                    )
                                    results["details"].append(
                                        f"STOPPED: {sm_name}/{execution['name']}"
                                    )
                                except ClientError as e:
                                    results["errors"].append(
                                        f"{sm_name}/{execution['name']}: {e}"
                                    )
                            results["stopped"] += 1
                except ClientError as e:
                    results["errors"].append(f"{sm_name} executions: {e}")
    except ClientError as e:
        results["errors"].append(f"ListStateMachines failed: {e}")

    logger.info(f"Step Functions: {results['discovered']} machines, {results['stopped']} executions stopped")
    return results


# ==========================================================================
# ECS SERVICES
# ==========================================================================

def scale_down_ecs_services():
    """Discover all ECS services and scale desired count to 0."""
    ecs = boto3.client("ecs")
    results = {"discovered": 0, "scaled_down": 0, "exempt": 0, "errors": [], "details": []}

    try:
        clusters = ecs.list_clusters().get("clusterArns", [])
        for cluster_arn in clusters:
            cluster_name = cluster_arn.split("/")[-1]
            try:
                svc_paginator = ecs.get_paginator("list_services")
                for svc_page in svc_paginator.paginate(cluster=cluster_arn):
                    svc_arns = svc_page.get("serviceArns", [])
                    if not svc_arns:
                        continue

                    services = ecs.describe_services(
                        cluster=cluster_arn, services=svc_arns
                    ).get("services", [])

                    for svc in services:
                        svc_name = svc["serviceName"]
                        results["discovered"] += 1

                        # Check tags
                        tags = {t["key"]: t["value"] for t in svc.get("tags", [])}
                        if _is_exempt(tags):
                            results["exempt"] += 1
                            results["details"].append(f"EXEMPT: {cluster_name}/{svc_name}")
                            continue

                        if svc.get("desiredCount", 0) == 0:
                            results["details"].append(
                                f"ALREADY AT 0: {cluster_name}/{svc_name}"
                            )
                            continue

                        if DRY_RUN:
                            results["details"].append(
                                f"[DRY RUN] Would scale to 0: {cluster_name}/{svc_name}"
                            )
                            results["scaled_down"] += 1
                        else:
                            try:
                                ecs.update_service(
                                    cluster=cluster_arn,
                                    service=svc_name,
                                    desiredCount=0,
                                )
                                results["details"].append(
                                    f"SCALED TO 0: {cluster_name}/{svc_name}"
                                )
                                results["scaled_down"] += 1
                            except ClientError as e:
                                results["errors"].append(
                                    f"{cluster_name}/{svc_name}: {e}"
                                )
            except ClientError as e:
                results["errors"].append(f"Cluster {cluster_name}: {e}")
    except ClientError as e:
        results["errors"].append(f"ListClusters failed: {e}")

    logger.info(f"ECS: {results['discovered']} services, {results['scaled_down']} scaled down")
    return results


# ==========================================================================
# EC2 INSTANCES (tagged CostProtection=enabled)
# ==========================================================================

def stop_tagged_ec2_instances():
    """Stop EC2 instances tagged with CostProtection=enabled."""
    ec2 = boto3.client("ec2")
    results = {"discovered": 0, "stopped": 0, "exempt": 0, "errors": [], "details": []}

    try:
        paginator = ec2.get_paginator("describe_instances")
        for page in paginator.paginate(
            Filters=[
                {"Name": "tag:CostProtection", "Values": [EC2_ENABLE_TAG_VALUE]},
                {"Name": "instance-state-name", "Values": ["running"]},
            ]
        ):
            for reservation in page.get("Reservations", []):
                for instance in reservation.get("Instances", []):
                    instance_id = instance["InstanceId"]
                    instance_type = instance.get("InstanceType", "unknown")
                    name_tag = next(
                        (t["Value"] for t in instance.get("Tags", []) if t["Key"] == "Name"),
                        "unnamed",
                    )
                    results["discovered"] += 1

                    if DRY_RUN:
                        results["details"].append(
                            f"[DRY RUN] Would stop: {instance_id} ({name_tag}, {instance_type})"
                        )
                        results["stopped"] += 1
                    else:
                        try:
                            ec2.stop_instances(InstanceIds=[instance_id])
                            results["details"].append(
                                f"STOPPED: {instance_id} ({name_tag}, {instance_type})"
                            )
                            results["stopped"] += 1
                        except ClientError as e:
                            results["errors"].append(f"{instance_id}: {e}")
    except ClientError as e:
        results["errors"].append(f"DescribeInstances failed: {e}")

    logger.info(f"EC2: {results['discovered']} tagged instances, {results['stopped']} stopped")
    return results


# ==========================================================================
# NOTIFICATION + SUMMARY
# ==========================================================================

def _build_summary(results):
    """Build a human-readable summary of all actions taken."""
    mode = "[DRY RUN] " if DRY_RUN else ""
    lines = [
        f"{'='*60}",
        f" {mode}COST CIRCUIT BREAKER TRIGGERED",
        f"{'='*60}",
        f"",
        f"Trigger: {results['trigger']}",
        f"Mode: {'DRY RUN (no actions taken)' if DRY_RUN else 'LIVE — resources disabled'}",
        f"",
        f"--- Summary ---",
        f"Lambda functions:  {results['lambda']['disabled']}/{results['lambda']['discovered']} disabled ({results['lambda']['exempt']} exempt)",
        f"REST APIs (v1):    {results['rest_api']['disabled']}/{results['rest_api']['discovered']} throttled ({results['rest_api']['exempt']} exempt)",
        f"HTTP APIs (v2):    {results['http_api']['disabled']}/{results['http_api']['discovered']} throttled ({results['http_api']['exempt']} exempt)",
        f"EventBridge rules: {results['eventbridge']['disabled']}/{results['eventbridge']['discovered']} disabled ({results['eventbridge']['exempt']} exempt)",
        f"Step Functions:    {results['step_functions']['stopped']}/{results['step_functions']['discovered']} stopped ({results['step_functions']['exempt']} exempt)",
        f"ECS services:      {results['ecs']['scaled_down']}/{results['ecs']['discovered']} scaled to 0 ({results['ecs']['exempt']} exempt)",
        f"EC2 instances:     {results['ec2']['stopped']}/{results['ec2']['discovered']} stopped",
        f"",
    ]

    # Add details for each resource type
    for resource_type, data in results.items():
        if resource_type in ("trigger", "dry_run"):
            continue
        details = data.get("details", [])
        errors = data.get("errors", [])
        if details or errors:
            lines.append(f"--- {resource_type} ---")
            for d in details:
                lines.append(f"  {d}")
            for e in errors:
                lines.append(f"  ERROR: {e}")
            lines.append("")

    if not DRY_RUN:
        lines.extend([
            "--- Recovery Commands ---",
            "# Re-enable all Lambda functions:",
            "aws lambda list-functions --query 'Functions[].FunctionName' --output text | tr '\\t' '\\n' | while read fn; do aws lambda delete-function-concurrency --function-name \"$fn\" 2>/dev/null; done",
            "",
            "# Re-enable REST API throttling (per API):",
            "aws apigateway update-stage --rest-api-id <ID> --stage-name prod --patch-operations op=replace,path='/*/*/throttling/rateLimit',value='10' op=replace,path='/*/*/throttling/burstLimit',value='20'",
            "",
            "# Re-enable EventBridge rules:",
            "aws events enable-rule --name <rule-name>",
            "",
            "# Start EC2 instances:",
            "aws ec2 start-instances --instance-ids <ids>",
            "",
            "# Scale up ECS services:",
            "aws ecs update-service --cluster <cluster> --service <service> --desired-count <N>",
            "",
        ])

    return "\n".join(lines)


def _send_sns_notification(summary, results):
    """Send the full summary to SNS for email delivery."""
    sns = boto3.client("sns")
    mode = "[DRY RUN] " if DRY_RUN else "[LIVE] "
    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"{mode}Cost Circuit Breaker Triggered",
            Message=summary[:262144],  # SNS max message size
        )
        logger.info("SNS notification sent")
    except ClientError as e:
        logger.error(f"Failed to send SNS notification: {e}")
