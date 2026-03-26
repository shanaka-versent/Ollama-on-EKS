"""API Key Manager Lambda — CRUD operations for self-service API keys.

Handles:
  GET    /portal/api/keys          — List user's keys
  POST   /portal/api/keys          — Create a new key
  PATCH  /portal/api/keys/{keyId}  — Disable/Enable a key
  DELETE /portal/api/keys/{keyId}  — Revoke a key (soft-delete)

Authentication: Reads user identity from the Open WebUI session token cookie.
CloudFront auth redirect + origin lockdown ensure only authenticated users
can reach these endpoints.
"""

import json
import os
import uuid
import base64
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


def _decode_jwt_payload(jwt_token):
    """Decode the payload from a JWT token string. Returns (user_id, email) or None."""
    try:
        payload = jwt_token.split(".")[1]
        # Add base64 padding
        payload += "=" * (4 - len(payload) % 4)
        # JWT uses base64url encoding (- and _ instead of + and /)
        decoded = json.loads(base64.urlsafe_b64decode(payload))
        user_id = decoded.get("id", decoded.get("sub", ""))
        user_email = decoded.get("email", "unknown")
        if user_id:
            logger.info("JWT decoded: user_id=%s, email=%s", user_id, user_email)
            return user_id, user_email
        logger.warning("JWT decoded but no 'id' or 'sub' field found: %s", list(decoded.keys()))
    except Exception as e:
        logger.warning("Failed to decode JWT: %s", e)
    return None


def _get_user_from_event(event):
    """Get user identity from Authorization header or Open WebUI session cookie.

    Auth chain:
      1. Cognito Authorizer claims (if API GW authorizer is configured)
      2. Authorization header (Bearer JWT or raw JWT)
      3. Open WebUI 'token' cookie (HttpOnly JWT set after OAuth login)
    """
    headers = event.get("headers") or {}

    # Debug: log headers received (cookie values redacted for security)
    cookie_raw = headers.get("Cookie", "") or headers.get("cookie", "")
    cookie_names = [p.strip().split("=")[0] for p in cookie_raw.split(";") if "=" in p] if cookie_raw else []
    auth_raw = headers.get("Authorization", "") or headers.get("authorization", "")
    logger.info("Auth debug: cookie_names=%s, auth_header_present=%s, auth_header_prefix=%s",
                cookie_names, bool(auth_raw), auth_raw[:20] if auth_raw else "none")

    # 1. Cognito Authorizer claims (if authorizer is configured on API GW method)
    try:
        claims = event["requestContext"]["authorizer"]["claims"]
        user_id = claims.get("sub", "")
        email = claims.get("email", "unknown")
        if user_id:
            logger.info("User from Cognito authorizer: user_id=%s, email=%s", user_id, email)
            return user_id, email
    except (KeyError, TypeError):
        pass

    # 2. Authorization header — accept both "Bearer <jwt>" and raw JWT
    if auth_raw:
        token_val = auth_raw[7:] if auth_raw.startswith("Bearer ") else auth_raw
        result = _decode_jwt_payload(token_val)
        if result:
            return result

    # 3. Open WebUI 'token' cookie (HttpOnly JWT, sent automatically by browser)
    for part in cookie_raw.split(";"):
        part = part.strip()
        if part.startswith("token="):
            result = _decode_jwt_payload(part[6:])
            if result:
                return result

    logger.warning("No valid user identity found (cookies: %s)", cookie_names)
    return "", "unknown"


def handler(event, context):
    method = event["httpMethod"]
    path = event.get("resource", "")

    user_id, user_email = _get_user_from_event(event)
    if not user_id:
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
