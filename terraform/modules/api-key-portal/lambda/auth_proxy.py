"""Auth Proxy Lambda — Custom login form bridge to Cognito + Open WebUI OAuth

@author Shanaka Jayasundera - shanakaj@gmail.com

Proxies the full Cognito hosted UI login flow server-side, allowing a custom
login form to authenticate users without showing Cognito's hosted UI.

Flow:
  1. Client POSTs email + password to /portal/api/auth/login
  2. Lambda starts Open WebUI's OAuth flow (/oauth/oidc/login)
  3. Lambda follows Cognito redirects and submits credentials
  4. If MFA required → returns challenge to client
  5. Client POSTs TOTP code to /portal/api/auth/mfa
  6. Lambda completes MFA and OAuth callback
  7. Lambda returns the Open WebUI session token via Set-Cookie
"""

import json
import os
import re
import base64
import urllib.request
import urllib.error
import urllib.parse

CLOUDFRONT_DOMAIN = os.environ['CLOUDFRONT_DOMAIN']
BASE_URL = f'https://{CLOUDFRONT_DOMAIN}'


def handler(event, context):
    """Route requests to login or MFA handlers."""
    path = event.get('path', '')
    method = event.get('httpMethod', '')

    if method == 'OPTIONS':
        return api_response(200, '')

    if method != 'POST':
        return api_response(405, {'error': 'Method not allowed'})

    if path == '/portal/api/auth/login':
        return handle_login(event)
    elif path == '/portal/api/auth/mfa':
        return handle_mfa(event)
    else:
        return api_response(404, {'error': 'Not found'})


def handle_login(event):
    """Handle initial login with email + password."""
    try:
        body = json.loads(event.get('body', '{}'))
    except (json.JSONDecodeError, TypeError):
        return api_response(400, {'error': 'Invalid request body'})

    email = body.get('email', '').strip()
    password = body.get('password', '')

    if not email or not password:
        return api_response(400, {'error': 'Email and password are required'})

    try:
        # Step 1: Start OAuth flow — GET /oauth/oidc/login
        # Open WebUI returns 303 → Cognito /authorize and sets owui-session cookie
        resp = http_get(f'{BASE_URL}/oauth/oidc/login')
        owui_session = resp['cookies'].get('owui-session', '')
        authorize_url = resp['location']

        if not owui_session or not authorize_url:
            print(f'Step 1 failed: status={resp["status"]}, has_location={bool(authorize_url)}')
            return api_response(500, {'error': 'Failed to start authentication flow'})

        # Step 2: Follow to Cognito /authorize → redirects to /login
        resp = http_get(authorize_url)
        login_page_url = resp['location']
        cognito_cookies = resp['cookies']

        if not login_page_url:
            print(f'Step 2 failed: status={resp["status"]}')
            return api_response(500, {'error': 'Failed to reach authentication provider'})

        # Resolve relative URL
        login_page_url = resolve_url(authorize_url, login_page_url)

        # Step 3: GET login page, extract CSRF token
        resp = http_get(login_page_url, cookies=cognito_cookies)
        cognito_cookies.update(resp['cookies'])
        csrf_token = extract_csrf(resp['body'])

        if not csrf_token:
            print('Step 3 failed: could not extract CSRF token from login page')
            return api_response(500, {'error': 'Failed to load login form'})

        # Step 4: POST credentials to Cognito login
        form_data = urllib.parse.urlencode({
            '_csrf': csrf_token,
            'username': email,
            'password': password,
            'cognitoAsfData': '',
        }).encode('utf-8')

        resp = http_post(login_page_url, data=form_data, cookies=cognito_cookies)
        cognito_cookies.update(resp['cookies'])
        redirect_url = resp['location']

        if not redirect_url:
            # Auth failed — Cognito returned the login page with an error
            error_msg = extract_error_message(resp['body'])
            return api_response(401, {'error': error_msg or 'Invalid email or password'})

        # Resolve relative URL
        redirect_url = resolve_url(login_page_url, redirect_url)

        # Cognito redirects back to /login on invalid credentials
        if '/login' in redirect_url and '/mfa' not in redirect_url and '/oauth/oidc/callback' not in redirect_url:
            return api_response(401, {'error': 'Invalid email or password'})

        # Check for password change required (first-time login)
        if '/newpassword' in redirect_url.lower() or '/changepassword' in redirect_url.lower() or '/confirmpassword' in redirect_url.lower():
            return api_response(403, {
                'error': 'initial_setup_required',
                'message': 'Please complete your initial setup (password change + MFA) by signing in through the setup link below.',
            })

        # Check if MFA is required
        if '/mfa' in redirect_url:
            state = json.dumps({
                'mfa_url': redirect_url,
                'cookies': cognito_cookies,
                'owui_session': owui_session,
            })
            encoded_state = base64.b64encode(state.encode()).decode()

            return api_response(200, {
                'status': 'mfa_required',
                'message': 'Enter the 6-digit code from your authenticator app',
                'session': encoded_state,
            })

        # Check if it's the callback URL (no MFA — shouldn't happen since MFA is required)
        if '/oauth/oidc/callback' in redirect_url:
            token_cookie = complete_callback(redirect_url, owui_session)
            if token_cookie:
                return api_response(200, {'status': 'success'}, set_cookie=token_cookie)
            return api_response(500, {'error': 'Failed to complete authentication'})

        print(f'Step 4 unexpected redirect: {redirect_url}')
        return api_response(500, {'error': 'Unexpected authentication response'})

    except Exception as e:
        print(f'Login error: {e}')
        import traceback
        traceback.print_exc()
        return api_response(500, {'error': 'Authentication failed. Please try again.'})


def handle_mfa(event):
    """Handle MFA verification with TOTP code."""
    try:
        body = json.loads(event.get('body', '{}'))
    except (json.JSONDecodeError, TypeError):
        return api_response(400, {'error': 'Invalid request body'})

    totp_code = body.get('totp_code', '').strip()
    encoded_state = body.get('session', '')

    if not totp_code or not encoded_state:
        return api_response(400, {'error': 'TOTP code and session are required'})

    if not re.match(r'^\d{6}$', totp_code):
        return api_response(400, {'error': 'TOTP code must be 6 digits'})

    try:
        state = json.loads(base64.b64decode(encoded_state))
        mfa_url = state['mfa_url']
        cognito_cookies = state['cookies']
        owui_session = state['owui_session']
    except (json.JSONDecodeError, KeyError) as e:
        print(f'State decode error: {e}')
        return api_response(400, {'error': 'Session expired. Please sign in again.'})

    try:
        # Step 5: GET MFA page, extract CSRF token
        resp = http_get(mfa_url, cookies=cognito_cookies)
        cognito_cookies.update(resp['cookies'])
        csrf_token = extract_csrf(resp['body'])

        if not csrf_token:
            print('MFA: could not extract CSRF token')
            return api_response(500, {'error': 'Failed to load MFA form'})

        # Step 6: POST TOTP code
        form_data = urllib.parse.urlencode({
            '_csrf': csrf_token,
            'code': totp_code,
            'cognitoAsfData': '',
        }).encode('utf-8')

        resp = http_post(mfa_url, data=form_data, cookies=cognito_cookies)
        redirect_url = resp['location']

        if not redirect_url:
            error_msg = extract_error_message(resp['body'])
            return api_response(401, {'error': error_msg or 'Invalid MFA code. Please try again.'})

        # Resolve relative URL
        redirect_url = resolve_url(mfa_url, redirect_url)

        # Check for callback URL → auth succeeded
        if '/oauth/oidc/callback' in redirect_url:
            token_cookie = complete_callback(redirect_url, owui_session)
            if token_cookie:
                return api_response(200, {'status': 'success'}, set_cookie=token_cookie)
            return api_response(500, {'error': 'Failed to complete authentication'})

        print(f'MFA unexpected redirect: {redirect_url}')
        return api_response(401, {'error': 'MFA verification failed'})

    except Exception as e:
        print(f'MFA error: {e}')
        import traceback
        traceback.print_exc()
        return api_response(500, {'error': 'MFA verification failed. Please try again.'})


def complete_callback(callback_url, owui_session):
    """Complete OAuth flow by calling Open WebUI's callback. Returns raw Set-Cookie for token."""
    # Step 7: GET /oauth/oidc/callback with owui-session cookie
    # Open WebUI exchanges auth code for tokens and sets the session token cookie
    resp = http_get(callback_url, cookies={'owui-session': owui_session})

    # Find the raw Set-Cookie header for 'token'
    for raw in resp['raw_set_cookies']:
        if raw.startswith('token='):
            return raw

    # Sometimes Open WebUI does a double redirect
    if resp['location']:
        resp2 = http_get(resp['location'], cookies={'owui-session': owui_session})
        for raw in resp2['raw_set_cookies']:
            if raw.startswith('token='):
                return raw

    print('complete_callback: no token cookie found in response')
    return None


# ==============================================================================
# HTTP HELPERS — No-redirect request handling
# ==============================================================================

class _RedirectCaught(Exception):
    """Raised when a redirect is caught instead of followed."""
    def __init__(self, code, headers, fp):
        self.code = code
        self.headers = headers
        self.fp = fp


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Catch redirects instead of following them."""
    def http_error_301(self, req, fp, code, msg, headers):
        raise _RedirectCaught(code, headers, fp)
    http_error_302 = http_error_303 = http_error_307 = http_error_308 = http_error_301


def http_get(url, cookies=None, timeout=25):
    """GET request without following redirects."""
    headers = {}
    if cookies:
        headers['Cookie'] = '; '.join(f'{k}={v}' for k, v in cookies.items())
    return _do_request(url, headers=headers, timeout=timeout)


def http_post(url, data, cookies=None, timeout=25):
    """POST request without following redirects."""
    headers = {'Content-Type': 'application/x-www-form-urlencoded'}
    if cookies:
        headers['Cookie'] = '; '.join(f'{k}={v}' for k, v in cookies.items())
    return _do_request(url, headers=headers, data=data, timeout=timeout)


def _do_request(url, headers=None, data=None, timeout=25):
    """Execute HTTP request and return structured response."""
    opener = urllib.request.build_opener(_NoRedirectHandler())
    req = urllib.request.Request(url, data=data, headers=headers or {})

    try:
        resp = opener.open(req, timeout=timeout)
        raw_set_cookies = resp.headers.get_all('Set-Cookie') or []
        return {
            'status': resp.status,
            'location': None,
            'cookies': _parse_set_cookies(raw_set_cookies),
            'raw_set_cookies': raw_set_cookies,
            'body': resp.read().decode('utf-8', errors='replace'),
        }
    except _RedirectCaught as e:
        raw_set_cookies = e.headers.get_all('Set-Cookie') or []
        return {
            'status': e.code,
            'location': e.headers.get('Location', ''),
            'cookies': _parse_set_cookies(raw_set_cookies),
            'raw_set_cookies': raw_set_cookies,
            'body': '',
        }
    except urllib.error.HTTPError as e:
        raw_set_cookies = e.headers.get_all('Set-Cookie') or []
        return {
            'status': e.code,
            'location': None,
            'cookies': _parse_set_cookies(raw_set_cookies),
            'raw_set_cookies': raw_set_cookies,
            'body': e.read().decode('utf-8', errors='replace'),
        }


def _parse_set_cookies(raw_headers):
    """Extract cookies from raw Set-Cookie header values."""
    cookies = {}
    for raw in raw_headers:
        kv = raw.split(';')[0]
        if '=' in kv:
            key, val = kv.split('=', 1)
            cookies[key.strip()] = val.strip()
    return cookies


def resolve_url(base_url, relative_url):
    """Resolve a relative URL against a base URL."""
    if relative_url.startswith('http://') or relative_url.startswith('https://'):
        return relative_url
    parsed = urllib.parse.urlparse(base_url)
    return f'{parsed.scheme}://{parsed.netloc}{relative_url}'


# ==============================================================================
# HTML PARSING HELPERS
# ==============================================================================

def extract_csrf(html):
    """Extract CSRF token from Cognito form HTML."""
    if not html:
        return ''
    # Try name before value
    match = re.search(r'name=["\']_csrf["\']\s+value=["\']([^"\']+)["\']', html)
    if match:
        return match.group(1)
    # Try value before name
    match = re.search(r'value=["\']([^"\']+)["\']\s+name=["\']_csrf["\']', html)
    if match:
        return match.group(1)
    # Try with type=hidden
    match = re.search(r'type=["\']hidden["\']\s+name=["\']_csrf["\']\s+value=["\']([^"\']+)["\']', html)
    if match:
        return match.group(1)
    return ''


def extract_error_message(html):
    """Extract error message from Cognito login/MFA page."""
    if not html:
        return ''
    # Cognito error message patterns
    for pattern in [
        r'<p[^>]*class="[^"]*errorMessage[^"]*"[^>]*>([^<]+)</p>',
        r'id="loginErrorMessage"[^>]*>([^<]+)<',
        r'class="[^"]*error[^"]*"[^>]*>([^<]+)<',
        r'<div[^>]*class="[^"]*banner-danger[^"]*"[^>]*>([^<]+)<',
    ]:
        match = re.search(pattern, html)
        if match:
            return match.group(1).strip()
    return ''


# ==============================================================================
# RESPONSE HELPERS
# ==============================================================================

def api_response(status_code, body, set_cookie=None):
    """Return API Gateway Lambda proxy response."""
    headers = {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': f'https://{CLOUDFRONT_DOMAIN}',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Allow-Methods': 'POST,OPTIONS',
    }

    if set_cookie:
        headers['Set-Cookie'] = set_cookie

    return {
        'statusCode': status_code,
        'headers': headers,
        'body': json.dumps(body) if isinstance(body, dict) else body,
    }
