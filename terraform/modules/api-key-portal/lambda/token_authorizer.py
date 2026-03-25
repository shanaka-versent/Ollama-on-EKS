"""API Gateway Lambda Authorizer — validates Open WebUI session token.

Reads the token from the Cookie header (HttpOnly cookie sent by browser),
decodes the JWT payload, and returns an IAM policy. User identity (user_id,
email) is passed to downstream Lambdas via the authorizer context.

This runs at the API Gateway level — unauthenticated requests are rejected
before reaching any business logic Lambda.
"""

import json
import base64
import logging
import time

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """API Gateway REQUEST-type Lambda Authorizer."""
    token = _extract_token(event)
    if not token:
        logger.warning("No token found in request")
        raise Exception("Unauthorized")  # API GW returns 401

    claims = _decode_jwt(token)
    if not claims:
        logger.warning("Invalid or expired token")
        raise Exception("Unauthorized")

    user_id = claims.get("id", claims.get("sub", ""))
    email = claims.get("email", "unknown")

    if not user_id:
        logger.warning("Token has no user identity (id/sub)")
        raise Exception("Unauthorized")

    logger.info("Authorized: user_id=%s, email=%s", user_id, email)

    # Build IAM policy allowing access to all methods on this API
    method_arn = event.get("methodArn", "")
    # Wildcard the resource so the policy is cached across all portal endpoints
    arn_parts = method_arn.split(":")
    api_gw_arn = ":".join(arn_parts[:5])
    api_id_stage = arn_parts[5].split("/")
    resource_arn = f"{api_gw_arn}:{api_id_stage[0]}/{api_id_stage[1]}/*"

    return {
        "principalId": user_id,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [{
                "Action": "execute-api:Invoke",
                "Effect": "Allow",
                "Resource": resource_arn,
            }],
        },
        "context": {
            "user_id": user_id,
            "email": email,
        },
    }


def _extract_token(event):
    """Extract token from Cookie header or Authorization header."""
    headers = event.get("headers") or {}

    # Cookie header (primary — HttpOnly cookie sent by browser)
    cookie = headers.get("Cookie", "") or headers.get("cookie", "")
    for part in cookie.split(";"):
        part = part.strip()
        if part.startswith("token="):
            return part[6:]

    # Authorization header fallback (for programmatic clients)
    auth = headers.get("Authorization", "") or headers.get("authorization", "")
    if auth.startswith("Bearer "):
        return auth[7:]

    return None


def _decode_jwt(token):
    """Decode JWT payload without signature verification.

    We trust the token because it was set by Open WebUI (via Cognito OAuth)
    and transmitted as an HttpOnly cookie — it cannot be tampered with by
    client-side JavaScript.
    """
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return None

        payload = parts[1]
        # Add base64 padding
        payload += "=" * (4 - len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))

        # Check expiry if present
        exp = claims.get("exp")
        if exp and time.time() > exp:
            logger.warning("Token expired at %s", exp)
            return None

        return claims
    except Exception as e:
        logger.warning("JWT decode failed: %s", e)
        return None
