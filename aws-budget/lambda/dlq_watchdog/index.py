"""
DLQ Failure Loop Watchdog
@author Shanaka Jayasundera - shanaka.jayasundera@versent.com.au

Triggered by CloudWatch alarms when any DLQ depth exceeds threshold.
Extracts the function name from the alarm name pattern "{function-name}-dlq-breach"
and sets that specific function's concurrency to 0 to stop the failure loop.

This is a targeted response — unlike the circuit breaker which disables everything,
the watchdog only disables the specific Lambda that is stuck in a retry loop.

Environment variables:
  SNS_TOPIC_ARN - SNS topic for sending notification
  DRY_RUN       - "true" to log actions without executing
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

# Parse exempt list from Terraform (JSON array)
def _parse_exempt_lambdas():
    raw = os.environ.get("EXEMPT_LAMBDAS", "")
    if not raw:
        return {"cost-circuit-breaker", "cost-dlq-watchdog"}
    try:
        return set(json.loads(raw)) | {"cost-circuit-breaker", "cost-dlq-watchdog"}
    except (json.JSONDecodeError, TypeError):
        return {"cost-circuit-breaker", "cost-dlq-watchdog"}

# Protected function names — never disabled (includes Terraform-managed exempt list)
SELF_PROTECTED = _parse_exempt_lambdas()


def handler(event, context):
    """Main handler — triggered by SNS from CloudWatch DLQ depth alarm."""
    logger.info(f"DLQ Watchdog triggered. DRY_RUN={DRY_RUN}")
    logger.info(f"Event: {json.dumps(event, default=str)}")

    for record in event.get("Records", []):
        sns_message = record.get("Sns", {}).get("Message", "")

        try:
            message = json.loads(sns_message)
        except (json.JSONDecodeError, TypeError):
            logger.warning(f"Could not parse SNS message: {sns_message[:200]}")
            continue

        alarm_name = message.get("AlarmName", "")
        new_state = message.get("NewStateValue", "")

        # Only act on ALARM state (not OK or INSUFFICIENT_DATA)
        if new_state != "ALARM":
            logger.info(f"Ignoring non-ALARM state: {new_state} for {alarm_name}")
            continue

        # Only process DLQ alarms matching the naming pattern
        if not alarm_name.endswith("-dlq-breach"):
            logger.info(f"Ignoring non-DLQ alarm: {alarm_name}")
            continue

        # Extract function name from alarm name: "{function-name}-dlq-breach"
        function_name = alarm_name.rsplit("-dlq-breach", 1)[0]

        if not function_name:
            logger.warning(f"Could not extract function name from alarm: {alarm_name}")
            continue

        # Self-protection check
        if function_name in SELF_PROTECTED:
            logger.warning(f"BLOCKED: Attempted to disable self-protected function: {function_name}")
            _notify(
                f"[BLOCKED] DLQ Watchdog refused to disable self-protected function: {function_name}",
                alarm_name,
            )
            continue

        # Disable the function
        _disable_function(function_name, alarm_name, message)

    return {"statusCode": 200}


def _disable_function(function_name, alarm_name, alarm_message):
    """Set the Lambda function's concurrency to 0 to stop the failure loop."""
    client = boto3.client("lambda")

    # Verify the function exists
    try:
        fn_info = client.get_function(FunctionName=function_name)
        fn_arn = fn_info["Configuration"]["FunctionArn"]
    except ClientError as e:
        logger.error(f"Function not found: {function_name} — {e}")
        _notify(
            f"DLQ Watchdog could not find function: {function_name}\nAlarm: {alarm_name}\nError: {e}",
            alarm_name,
        )
        return

    reason = alarm_message.get("NewStateReason", "DLQ depth exceeded threshold")

    if DRY_RUN:
        logger.info(f"[DRY RUN] Would disable function: {function_name}")
        _notify(
            f"[DRY RUN] DLQ Watchdog would disable function: {function_name}\n"
            f"Alarm: {alarm_name}\n"
            f"Reason: {reason}\n"
            f"Function ARN: {fn_arn}",
            alarm_name,
        )
    else:
        try:
            client.put_function_concurrency(
                FunctionName=function_name,
                ReservedConcurrentExecutions=0,
            )
            logger.info(f"DISABLED function: {function_name} (concurrency set to 0)")
            _notify(
                f"DLQ Watchdog DISABLED function: {function_name}\n"
                f"Action: Set ReservedConcurrentExecutions = 0\n"
                f"Alarm: {alarm_name}\n"
                f"Reason: {reason}\n"
                f"Function ARN: {fn_arn}\n\n"
                f"Recovery command:\n"
                f"  aws lambda delete-function-concurrency --function-name {function_name}",
                alarm_name,
            )
        except ClientError as e:
            logger.error(f"Failed to disable function {function_name}: {e}")
            _notify(
                f"DLQ Watchdog FAILED to disable function: {function_name}\n"
                f"Error: {e}\n"
                f"Alarm: {alarm_name}",
                alarm_name,
            )


def _notify(message, alarm_name):
    """Send notification via SNS."""
    if not SNS_TOPIC_ARN:
        return

    sns = boto3.client("sns")
    mode = "[DRY RUN] " if DRY_RUN else ""
    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"{mode}DLQ Watchdog: {alarm_name}",
            Message=message,
        )
    except ClientError as e:
        logger.error(f"Failed to send SNS notification: {e}")
