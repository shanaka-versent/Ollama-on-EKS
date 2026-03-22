"""API Key Manager Lambda — CRUD operations for self-service API keys.

Handles:
  GET    /portal/api/keys          — List user's keys
  POST   /portal/api/keys          — Create a new key
  PATCH  /portal/api/keys/{keyId}  — Disable/Enable a key
  DELETE /portal/api/keys/{keyId}  — Revoke a key (soft-delete)

Authentication: Cognito JWT via API Gateway authorizer.
The user's identity comes from requestContext.authorizer.claims.
"""

import json
import os
import uuid
import logging
from datetime import datetime, timedelta, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

apigw = boto3.client("apigateway")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMO_TABLE"])

USAGE_PLAN_ID = os.environ["USAGE_PLAN_ID"]
PROJECT_NAME = os.environ["PROJECT_NAME"]
MAX_KEYS = int(os.environ.get("MAX_KEYS_PER_USER", "5"))
DEFAULT_EXPIRY_DAYS = int(os.environ.get("KEY_EXPIRY_DAYS", "90"))
VALID_EXPIRY_OPTIONS = [0, 7, 30, 90]


def handler(event, context):
    method = event["httpMethod"]
    path = event.get("resource", "")

    try:
        claims = event["requestContext"]["authorizer"]["claims"]
        user_id = claims.get("sub", "")
        user_email = claims.get("email", "unknown")
    except (KeyError, TypeError):
        return _response(401, {"error": "Unauthorized"})

    try:
        if method == "GET" and path == "/portal/api/keys":
            return list_keys(user_id)
        elif method == "POST" and path == "/portal/api/keys":
            body = json.loads(event.get("body") or "{}")
            return create_key(user_id, user_email, body)
        elif method == "PATCH" and "/keys/" in path:
            key_id = event["pathParameters"]["keyId"]
            body = json.loads(event.get("body") or "{}")
            return update_key(user_id, key_id, body)
        elif method == "DELETE" and "/keys/" in path:
            key_id = event["pathParameters"]["keyId"]
            return revoke_key(user_id, user_email, key_id)
        else:
            return _response(404, {"error": "Not found"})
    except Exception as e:
        logger.exception("Unhandled error")
        return _response(500, {"error": str(e)})


def list_keys(user_id):
    """List all keys belonging to the authenticated user."""
    result = table.query(
        IndexName="cognitoUserId-index",
        KeyConditionExpression="cognitoUserId = :uid",
        ExpressionAttributeValues={":uid": user_id},
    )
    keys = []
    for item in result.get("Items", []):
        keys.append({
            "keyId": item["keyId"],
            "keyName": item.get("keyName", ""),
            "createdDate": item.get("createdDate", ""),
            "expiryDate": item.get("expiryDate", ""),
            "status": item.get("status", "active"),
            "lastUpdated": item.get("lastUpdated", ""),
        })
    return _response(200, {"keys": keys})


def create_key(user_id, user_email, body):
    """Create a new API Gateway key and record metadata."""
    # Check key limit
    existing = table.query(
        IndexName="cognitoUserId-index",
        KeyConditionExpression="cognitoUserId = :uid",
        ExpressionAttributeValues={":uid": user_id},
        Select="COUNT",
    )
    active_count = 0
    if existing["Count"] > 0:
        all_keys = table.query(
            IndexName="cognitoUserId-index",
            KeyConditionExpression="cognitoUserId = :uid",
            ExpressionAttributeValues={":uid": user_id},
        )
        active_count = sum(
            1 for k in all_keys["Items"] if k.get("status") in ("active", "disabled")
        )
    if active_count >= MAX_KEYS:
        return _response(
            400, {"error": f"Maximum {MAX_KEYS} active keys allowed. Revoke an existing key first."}
        )

    key_name = body.get("name", "").strip() or f"key-{uuid.uuid4().hex[:8]}"
    expiry_days = body.get("expiryDays", DEFAULT_EXPIRY_DAYS)
    if expiry_days not in VALID_EXPIRY_OPTIONS:
        expiry_days = DEFAULT_EXPIRY_DAYS

    now = datetime.now(timezone.utc)
    short_id = uuid.uuid4().hex[:8]
    apigw_key_name = f"{user_email}-{short_id}-{now.strftime('%Y%m%d')}"

    # Create API Gateway key
    tags = {
        "cognito-user": user_id,
        "cognito-email": user_email,
        "created-date": now.isoformat(),
        "portal-managed": "true",
    }
    if expiry_days > 0:
        expiry = now + timedelta(days=expiry_days)
        tags["expiry-date"] = expiry.isoformat()
    else:
        expiry = None

    api_key = apigw.create_api_key(
        name=apigw_key_name,
        enabled=True,
        tags=tags,
    )

    # Associate with usage plan
    apigw.create_usage_plan_key(
        usagePlanId=USAGE_PLAN_ID,
        keyId=api_key["id"],
        keyType="API_KEY",
    )

    # Write metadata to DynamoDB
    item = {
        "keyId": api_key["id"],
        "cognitoUserId": user_id,
        "cognitoUsername": user_email,
        "keyName": key_name,
        "createdDate": now.isoformat(),
        "status": "active",
        "lastUpdated": now.isoformat(),
    }
    if expiry:
        item["expiryDate"] = expiry.isoformat()
    table.put_item(Item=item)

    logger.info("Key created: %s for user %s", api_key["id"], user_email)

    return _response(201, {
        "keyId": api_key["id"],
        "keyName": key_name,
        "keyValue": api_key["value"],  # Only shown once
        "createdDate": now.isoformat(),
        "expiryDate": expiry.isoformat() if expiry else None,
        "status": "active",
    })


def update_key(user_id, key_id, body):
    """Disable or enable a key (ownership verified)."""
    item = table.get_item(Key={"keyId": key_id}).get("Item")
    if not item or item.get("cognitoUserId") != user_id:
        return _response(404, {"error": "Key not found"})
    if item.get("status") in ("revoked", "expired"):
        return _response(400, {"error": f"Cannot update a {item['status']} key"})

    action = body.get("action", "")
    if action == "disable":
        apigw.update_api_key(
            apiKey=key_id,
            patchOperations=[{"op": "replace", "path": "/enabled", "value": "false"}],
        )
        new_status = "disabled"
    elif action == "enable":
        apigw.update_api_key(
            apiKey=key_id,
            patchOperations=[{"op": "replace", "path": "/enabled", "value": "true"}],
        )
        new_status = "active"
    else:
        return _response(400, {"error": "action must be 'disable' or 'enable'"})

    now = datetime.now(timezone.utc).isoformat()
    table.update_item(
        Key={"keyId": key_id},
        UpdateExpression="SET #s = :s, lastUpdated = :t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":s": new_status, ":t": now},
    )

    logger.info("Key %s %sd by user %s", key_id, action, user_id)
    return _response(200, {"keyId": key_id, "status": new_status})


def revoke_key(user_id, user_email, key_id):
    """Permanently revoke a key — deletes from API Gateway, keeps audit record."""
    item = table.get_item(Key={"keyId": key_id}).get("Item")
    if not item or item.get("cognitoUserId") != user_id:
        return _response(404, {"error": "Key not found"})
    if item.get("status") == "revoked":
        return _response(400, {"error": "Key already revoked"})

    # Delete from API Gateway (removes from usage plan automatically)
    try:
        apigw.delete_api_key(apiKey=key_id)
    except apigw.exceptions.NotFoundException:
        pass  # Already deleted from API Gateway

    now = datetime.now(timezone.utc).isoformat()
    table.update_item(
        Key={"keyId": key_id},
        UpdateExpression="SET #s = :s, revokedDate = :d, revokedBy = :b, lastUpdated = :t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "revoked",
            ":d": now,
            ":b": user_email,
            ":t": now,
        },
    )

    logger.info("Key %s revoked by user %s", key_id, user_email)
    return _response(200, {"keyId": key_id, "status": "revoked"})


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
        },
        "body": json.dumps(body),
    }
