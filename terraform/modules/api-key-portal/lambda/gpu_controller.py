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
import urllib.request
import urllib.error
import boto3
from botocore.signers import RequestSigner

CLUSTER_NAME = os.environ['EKS_CLUSTER_NAME']
REGION = os.environ.get('AWS_REGION', 'ap-southeast-2')
NAMESPACE = os.environ.get('OLLAMA_NAMESPACE', 'ollama')
DEPLOYMENT = os.environ.get('OLLAMA_DEPLOYMENT', 'ollama')
SCALED_OBJECT = os.environ.get('KEDA_SCALED_OBJECT', 'ollama-autoscaler')

# Cache cluster info across invocations (Lambda container reuse)
_cluster_info = None


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
# HANDLER
# ==============================================================================

def handler(event, context):
    """Route requests to appropriate handlers."""
    path = event.get('path', '')
    method = event.get('httpMethod', '')

    if method == 'OPTIONS':
        return api_response(200, '')

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
        # Step 1: Pause KEDA so it doesn't scale back to 0
        try:
            k8s_request(
                'PATCH',
                f'/apis/keda.sh/v1alpha1/namespaces/{NAMESPACE}'
                f'/scaledobjects/{SCALED_OBJECT}',
                {'metadata': {'annotations': {
                    'autoscaling.keda.sh/paused': 'true',
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
