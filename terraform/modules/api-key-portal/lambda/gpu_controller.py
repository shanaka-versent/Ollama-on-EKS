"""GPU Controller Lambda — Self-service GPU start/stop/status for Open WebUI

@author Shanaka Jayasundera - shanakaj@gmail.com

Provides API endpoints to check Ollama GPU status and start/stop the GPU node
without requiring kubectl access. Uses the K8s API directly via EKS bearer
token authentication (STS presigned URL).

Endpoints:
  GET  /portal/api/gpu/status — Current GPU status (running/stopped/starting)
  POST /portal/api/gpu/start  — Pause KEDA + scale Ollama to 1
  POST /portal/api/gpu/stop   — Scale Ollama to 0 + unpause KEDA
"""

import json
import os
import base64
import ssl
import time
import urllib.request
import urllib.error
import boto3
from botocore.signers import RequestSigner

CLUSTER_NAME = os.environ['EKS_CLUSTER_NAME']
REGION = os.environ.get('AWS_REGION', 'ap-southeast-2')
NAMESPACE = os.environ.get('OLLAMA_NAMESPACE', 'ollama')
DEPLOYMENT = os.environ.get('OLLAMA_DEPLOYMENT', 'ollama')
SCALED_OBJECT = os.environ.get('KEDA_SCALED_OBJECT', 'ollama-autoscaler')
CLOUDFRONT_DOMAIN = os.environ.get('CLOUDFRONT_DOMAIN', '')

# Cache cluster info across invocations (Lambda container reuse)
_cluster_info = None
# Cache verified user roles (token prefix → role/email/timestamp)
_role_cache = {}
_ROLE_CACHE_TTL = 300  # 5 minutes


# ==============================================================================
# EKS AUTHENTICATION
# ==============================================================================

def get_cluster_info():
    """Get EKS cluster endpoint and CA certificate (cached)."""
    global _cluster_info
    if _cluster_info:
        return _cluster_info
    eks = boto3.client('eks', region_name=REGION)
    cluster = eks.describe_cluster(name=CLUSTER_NAME)['cluster']
    _cluster_info = {
        'endpoint': cluster['endpoint'],
        'ca_data': cluster['certificateAuthority']['data'],
    }
    return _cluster_info


def get_bearer_token():
    """Generate a short-lived EKS bearer token via STS presigned URL."""
    client = boto3.client('sts', region_name=REGION)
    service_id = client.meta.service_model.service_id

    signer = RequestSigner(
        service_id,
        REGION,
        'sts',
        'v4',
        client._request_signer._credentials,
        client.meta.events,
    )

    params = {
        'method': 'GET',
        'url': f'https://sts.{REGION}.amazonaws.com/'
               f'?Action=GetCallerIdentity&Version=2011-06-15',
        'body': {},
        'headers': {'x-k8s-aws-id': CLUSTER_NAME},
        'context': {},
    }

    signed_url = signer.generate_presigned_url(
        params, region_name=REGION, expires_in=60, operation_name='',
    )

    encoded = base64.urlsafe_b64encode(signed_url.encode('utf-8')).decode('utf-8')
    return 'k8s-aws-v1.' + encoded.rstrip('=')


# ==============================================================================
# KUBERNETES API CLIENT
# ==============================================================================

def k8s_request(method, path, body=None):
    """Execute a request against the EKS Kubernetes API."""
    info = get_cluster_info()
    token = get_bearer_token()
    url = f'{info["endpoint"]}{path}'

    headers = {
        'Authorization': f'Bearer {token}',
        'Accept': 'application/json',
    }

    if body is not None:
        headers['Content-Type'] = 'application/merge-patch+json'
        data = json.dumps(body).encode('utf-8')
    else:
        data = None

    req = urllib.request.Request(url, data=data, headers=headers, method=method)

    # TLS verification with EKS cluster CA
    ca_pem = base64.b64decode(info['ca_data']).decode('utf-8')
    ctx = ssl.create_default_context(cadata=ca_pem)

    try:
        resp = urllib.request.urlopen(req, context=ctx, timeout=10)
        return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode('utf-8', errors='replace')
        print(f'K8s API error: {method} {path} → {e.code}: {error_body[:500]}')
        raise


# ==============================================================================
# AUTH — Admin-only access via Open WebUI API verification
# ==============================================================================

def _extract_token(event):
    """Extract the Open WebUI session token from Authorization header or Cookie."""
    headers = event.get('headers') or {}
    # Primary: Authorization header (portal JS sends "Bearer <jwt>" from localStorage)
    auth = headers.get('Authorization', '') or headers.get('authorization', '')
    if auth.startswith('Bearer '):
        return auth[7:]
    if auth:
        return auth
    # Fallback: token cookie (for direct browser requests)
    cookie_header = headers.get('Cookie', '') or headers.get('cookie', '')
    for part in cookie_header.split(';'):
        part = part.strip()
        if part.startswith('token='):
            return part[6:]
    return None


def get_user_role(event):
    """Verify user role by calling Open WebUI's API with the session token.

    The Open WebUI JWT only contains id/exp/jti — no role or email.
    We call GET /api/v1/auths/ with the token to get the full user profile.
    Roles are Cognito-managed and synced to Open WebUI via ENABLE_OAUTH_ROLE_MANAGEMENT.

    Results are cached for 5 minutes per Lambda container to avoid timeout issues
    on repeated calls (e.g., status polling from gpu.html).
    """
    token = _extract_token(event)
    if not token:
        print('No token cookie found')
        return '', 'unknown'

    # Check in-memory cache (survives across invocations in same Lambda container)
    cache_key = token[:32]
    if cache_key in _role_cache:
        cached = _role_cache[cache_key]
        if time.time() - cached['ts'] < _ROLE_CACHE_TTL:
            return cached['role'], cached['email']

    if not CLOUDFRONT_DOMAIN:
        print('CLOUDFRONT_DOMAIN not configured — cannot verify user role')
        return '', 'unknown'

    try:
        url = f'https://{CLOUDFRONT_DOMAIN}/api/v1/auths/'
        req = urllib.request.Request(url, headers={
            'Authorization': f'Bearer {token}',
            'Accept': 'application/json',
        })
        resp = urllib.request.urlopen(req, timeout=8)
        user_info = json.loads(resp.read().decode('utf-8'))
        role = user_info.get('role', '')
        email = user_info.get('email', 'unknown')
        # Cache successful verification
        _role_cache[cache_key] = {'role': role, 'email': email, 'ts': time.time()}
        print(f'User verified: role={role}, email={email}')
        return role, email
    except Exception as e:
        print(f'Open WebUI verification failed: {e}')
        # Fall back to cache with extended TTL (30 min) on transient failures
        if cache_key in _role_cache:
            cached = _role_cache[cache_key]
            if time.time() - cached['ts'] < 1800:
                print(f'Using cached role: {cached["role"]} ({cached["email"]})')
                return cached['role'], cached['email']
        return '', 'unknown'


# ==============================================================================
# HANDLER
# ==============================================================================

KEDA_GRACE_MINUTES = int(os.environ.get('KEDA_GRACE_MINUTES', '30'))


def handler(event, context):
    """Route requests to appropriate handlers. Admin-only access.

    Also handles EventBridge scheduled invocations for the KEDA safety check.
    """
    # EventBridge scheduled rule — check if KEDA has been paused too long
    if event.get('source') == 'aws.events' or event.get('detail-type') == 'Scheduled Event':
        return handle_keda_safety_check()

    path = event.get('path', '')
    method = event.get('httpMethod', '')

    if method == 'OPTIONS':
        return api_response(200, '')

    # Auth is enforced by: CloudFront Function (token cookie required) +
    # client-side admin check in gpu.html (Open WebUI API) +
    # origin lockdown (only CloudFront can call API Gateway).
    # Lambda-side role check removed — CloudFront→OpenWebUI call was unreliable.

    routes = {
        ('GET', '/portal/api/gpu/status'): handle_status,
        ('POST', '/portal/api/gpu/start'): handle_start,
        ('POST', '/portal/api/gpu/stop'): handle_stop,
    }

    handler_fn = routes.get((method, path))
    if handler_fn:
        return handler_fn()
    return api_response(404, {'error': 'Not found'})


# ==============================================================================
# GPU STATUS
# ==============================================================================

def handle_status():
    """Return current GPU/Ollama status."""
    try:
        # Get deployment state
        deploy = k8s_request(
            'GET',
            f'/apis/apps/v1/namespaces/{NAMESPACE}/deployments/{DEPLOYMENT}',
        )
        replicas = deploy.get('spec', {}).get('replicas', 0)
        ready = deploy.get('status', {}).get('readyReplicas') or 0

        if replicas == 0:
            status = 'stopped'
        elif ready >= 1:
            status = 'running'
        else:
            status = 'starting'

        # Get KEDA paused state
        keda_paused = False
        try:
            so = k8s_request(
                'GET',
                f'/apis/keda.sh/v1alpha1/namespaces/{NAMESPACE}'
                f'/scaledobjects/{SCALED_OBJECT}',
            )
            paused_val = (so.get('metadata', {}).get('annotations', {})
                          .get('autoscaling.keda.sh/paused', '0'))
            keda_paused = paused_val == 'true'
        except Exception:
            pass  # KEDA might not be installed

        # NOTE: Do NOT auto-unpause KEDA here. KEDA's initialCooldownPeriod
        # does not apply when unpausing via annotation — KEDA immediately
        # checks triggers and scales to 0 if no CPU activity exists yet
        # (e.g., during model loading). KEDA stays paused during manual
        # start; the Stop button unpauses it. A scheduled safety Lambda
        # can handle the "forgotten GPU" scenario separately.

        return api_response(200, {
            'status': status,
            'replicas': replicas,
            'ready_replicas': ready,
            'keda_paused': keda_paused,
        })

    except Exception as e:
        print(f'Status error: {e}')
        return api_response(500, {'error': 'Failed to get GPU status'})


# ==============================================================================
# GPU START
# ==============================================================================

def handle_start():
    """Pause KEDA and scale Ollama to 1 replica."""
    try:
        # Step 1: Pause KEDA and record when it was paused (ISO 8601 UTC).
        # The safety check uses this timestamp to auto-unpause after grace period.
        pause_time = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        try:
            k8s_request(
                'PATCH',
                f'/apis/keda.sh/v1alpha1/namespaces/{NAMESPACE}'
                f'/scaledobjects/{SCALED_OBJECT}',
                {'metadata': {'annotations': {
                    'autoscaling.keda.sh/paused': 'true',
                    'gpu-controller/paused-at': pause_time,
                }}},
            )
        except Exception as e:
            print(f'KEDA pause warning (non-fatal): {e}')

        # Step 2: Scale deployment to 1
        k8s_request(
            'PATCH',
            f'/apis/apps/v1/namespaces/{NAMESPACE}'
            f'/deployments/{DEPLOYMENT}/scale',
            {'spec': {'replicas': 1}},
        )

        return api_response(200, {
            'status': 'starting',
            'message': 'GPU node is starting. Cold start takes ~3 minutes.',
        })

    except Exception as e:
        print(f'Start error: {e}')
        return api_response(500, {'error': 'Failed to start GPU'})


# ==============================================================================
# GPU STOP
# ==============================================================================

def handle_stop():
    """Scale Ollama to 0 and unpause KEDA."""
    try:
        # Step 1: Scale deployment to 0
        k8s_request(
            'PATCH',
            f'/apis/apps/v1/namespaces/{NAMESPACE}'
            f'/deployments/{DEPLOYMENT}/scale',
            {'spec': {'replicas': 0}},
        )

        # Step 2: Unpause KEDA
        try:
            k8s_request(
                'PATCH',
                f'/apis/keda.sh/v1alpha1/namespaces/{NAMESPACE}'
                f'/scaledobjects/{SCALED_OBJECT}',
                {'metadata': {'annotations': {
                    'autoscaling.keda.sh/paused': '0',
                }}},
            )
        except Exception as e:
            print(f'KEDA unpause warning (non-fatal): {e}')

        return api_response(200, {
            'status': 'stopped',
            'message': 'GPU scaling down. Node terminates in ~10 minutes.',
        })

    except Exception as e:
        print(f'Stop error: {e}')
        return api_response(500, {'error': 'Failed to stop GPU'})


# ==============================================================================
# KEDA SAFETY CHECK (EventBridge scheduled)
# ==============================================================================

def handle_keda_safety_check():
    """Auto-unpause KEDA if it's been paused longer than the grace period.

    Invoked by EventBridge every 5 minutes. If KEDA has been paused for
    longer than KEDA_GRACE_MINUTES (default 30), unpause it so KEDA's
    idle detection takes over. This prevents forgotten GPU starts from
    running indefinitely.

    Flow: manual start → KEDA paused (30 min grace) → this check unpauses
    → KEDA checks triggers → if active, keeps running; if idle, scales to 0.
    """
    try:
        so = k8s_request(
            'GET',
            f'/apis/keda.sh/v1alpha1/namespaces/{NAMESPACE}'
            f'/scaledobjects/{SCALED_OBJECT}',
        )
        annotations = so.get('metadata', {}).get('annotations', {})
        paused_val = annotations.get('autoscaling.keda.sh/paused', '0')

        if paused_val != 'true':
            print('KEDA safety check: not paused, nothing to do')
            return {'status': 'ok', 'action': 'none'}

        paused_at = annotations.get('gpu-controller/paused-at', '')
        if not paused_at:
            print('KEDA safety check: paused but no timestamp — unpausing now')
        else:
            import calendar
            paused_ts = calendar.timegm(time.strptime(paused_at, '%Y-%m-%dT%H:%M:%SZ'))
            elapsed_min = (time.time() - paused_ts) / 60
            print(f'KEDA safety check: paused for {elapsed_min:.1f} min '
                  f'(grace: {KEDA_GRACE_MINUTES} min)')
            if elapsed_min < KEDA_GRACE_MINUTES:
                return {'status': 'ok', 'action': 'within_grace',
                        'elapsed_min': round(elapsed_min, 1)}

        # Grace period exceeded — unpause KEDA
        k8s_request(
            'PATCH',
            f'/apis/keda.sh/v1alpha1/namespaces/{NAMESPACE}'
            f'/scaledobjects/{SCALED_OBJECT}',
            {'metadata': {'annotations': {
                'autoscaling.keda.sh/paused': '0',
                'gpu-controller/paused-at': '',
            }}},
        )
        print('KEDA safety check: unpaused KEDA — idle auto-shutdown now active')
        return {'status': 'ok', 'action': 'unpaused'}

    except Exception as e:
        print(f'KEDA safety check error: {e}')
        return {'status': 'error', 'message': str(e)}


# ==============================================================================
# RESPONSE HELPER
# ==============================================================================

def api_response(status_code, body):
    """Return API Gateway Lambda proxy response."""
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
        },
        'body': json.dumps(body) if isinstance(body, (dict, list)) else body,
    }
