"""API Key Expiry Checker Lambda — disables expired keys nightly.

Triggered by EventBridge daily at 2 AM UTC.
Scans DynamoDB for active keys past their expiry date,
disables them in API Gateway, and updates the audit record.
"""

import os
import logging
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

apigw = boto3.client("apigateway")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMO_TABLE"])


def handler(event, context):
    now = datetime.now(timezone.utc)
    now_iso = now.isoformat()
    expired_count = 0

    # Scan for active keys with an expiry date in the past
    scan_kwargs = {
        "FilterExpression": "#s = :active AND attribute_exists(expiryDate)",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":active": "active"},
    }

    while True:
        result = table.scan(**scan_kwargs)

        for item in result.get("Items", []):
            expiry_str = item.get("expiryDate", "")
            if not expiry_str:
                continue

            try:
                expiry = datetime.fromisoformat(expiry_str)
            except ValueError:
                logger.warning("Invalid expiryDate for key %s: %s", item["keyId"], expiry_str)
                continue

            if expiry > now:
                continue  # Not expired yet

            key_id = item["keyId"]
            logger.info("Expiring key %s (expired %s)", key_id, expiry_str)

            # Disable in API Gateway
            try:
                apigw.update_api_key(
                    apiKey=key_id,
                    patchOperations=[
                        {"op": "replace", "path": "/enabled", "value": "false"}
                    ],
                )
            except Exception as e:
                logger.error("Failed to disable key %s in API Gateway: %s", key_id, e)
                continue

            # Update DynamoDB record
            table.update_item(
                Key={"keyId": key_id},
                UpdateExpression="SET #s = :s, lastUpdated = :t",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":s": "expired", ":t": now_iso},
            )
            expired_count += 1

        # Handle pagination
        if "LastEvaluatedKey" in result:
            scan_kwargs["ExclusiveStartKey"] = result["LastEvaluatedKey"]
        else:
            break

    logger.info("Expiry check complete: %d keys expired", expired_count)
    return {"expired": expired_count}
