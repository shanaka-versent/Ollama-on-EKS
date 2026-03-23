"""Auth Proxy Lambda — Custom login form bridge to Cognito + Open WebUI OAuth

@author Shanaka Jayasundera - shanakaj@gmail.com

Proxies the full Cognito hosted UI login flow server-side, allowing a custom
login form to authenticate users without showing Cognito's hosted UI.

Also handles first-time setup (password change + MFA enrollment) and forgot
password flows via Cognito Admin APIs, so the user NEVER sees the Cognito
hosted UI.

Endpoints:
  POST /portal/api/auth/login          — Email + password login
  POST /portal/api/auth/mfa            — TOTP MFA verification
  POST /portal/api/auth/change-password — First-time password change (NEW_PASSWORD_REQUIRED)
  POST /portal/api/auth/setup-mfa      — First-time MFA enrollment (associate + verify TOTP)
  POST /portal/api/auth/forgot-password — Initiate forgot password (sends code via email)
  POST /portal/api/auth/confirm-reset  — Confirm forgot password (code + new password)

Flow (normal login):
  1. Client POSTs email + password to /portal/api/auth/login
  2. Lambda starts Open WebUI's OAuth flow (/oauth/oidc/login)
  3. Lambda follows Cognito redirects and submits credentials
  4. If MFA required → returns challenge to client
  5. Client POSTs TOTP code to /portal/api/auth/mfa
  6. Lambda completes MFA and OAuth callback
  7. Lambda returns the Open WebUI session token via Set-Cookie

Flow (first-time login):
  1. Client POSTs email + password → Lambda detects NEW_PASSWORD_REQUIRED
  2. Returns {status: 'new_password_required', session: ...}
  3. Client POSTs new password to /portal/api/auth/change-password
  4. Lambda responds to challenge → detects MFA_SETUP
  5. Returns {status: 'mfa_setup_required', secret: ..., qr_uri: ..., session: ...}
  6. Client shows QR code, user scans with authenticator app
  7. Client POSTs TOTP code to /portal/api/auth/setup-mfa
  8. Lambda verifies TOTP and completes setup → redirects to normal login

Flow (forgot password):
  1. Client POSTs email to /portal/api/auth/forgot-password
  2. Cognito sends verification code via email
  3. Client POSTs email + code + new password to /portal/api/auth/confirm-reset
  4. Password is reset → user can sign in normally
"""

import json
import os
import re
import base64
import hmac
import hashlib
import urllib.request
import urllib.error
import urllib.parse

CLOUDFRONT_DOMAIN = os.environ['CLOUDFRONT_DOMAIN']
USER_POOL_ID = os.environ.get('USER_POOL_ID', '')
CLIENT_ID = os.environ.get('COGNITO_CLIENT_ID', '')
CLIENT_SECRET = os.environ.get('COGNITO_CLIENT_SECRET', '')
REGION = os.environ.get('AWS_REGION', 'ap-southeast-2')
BASE_URL = f'https://{CLOUDFRONT_DOMAIN}'
COGNITO_ENDPOINT = f'https://cognito-idp.{REGION}.amazonaws.com/'


def handler(event, context):
    """Route requests to appropriate handlers."""
    path = event.get('path', '')
    method = event.get('httpMethod', '')

    if method == 'OPTIONS':
        return api_response(200, '')

    if method != 'POST':
        return api_response(405, {'error': 'Method not allowed'})

    routes = {
        '/portal/api/auth/login': handle_login,
        '/portal/api/auth/mfa': handle_mfa,
        '/portal/api/auth/change-password': handle_change_password,
        '/portal/api/auth/setup-mfa': handle_setup_mfa,
        '/portal/api/auth/forgot-password': handle_forgot_password,
        '/portal/api/auth/confirm-reset': handle_confirm_reset,
    }

    handler_fn = routes.get(path)
    if handler_fn:
        return handler_fn(event)
    return api_response(404, {'error': 'Not found'})


# ==============================================================================
# REQUEST BODY PARSER
# ==============================================================================

def parse_body(event):
    """Parse request body, handling API Gateway base64 encoding."""
    raw_body = event.get('body', '{}')
    if event.get('isBase64Encoded') and raw_body:
        raw_body = base64.b64decode(raw_body).decode('utf-8')
    return json.loads(raw_body or '{}')


# ==============================================================================
# COGNITO SECRET HASH HELPER
# ==============================================================================

def compute_secret_hash(username):
    """Compute Cognito SECRET_HASH for app clients with a client secret."""
    if not CLIENT_SECRET:
        return None
    msg = username + CLIENT_ID
    dig = hmac.new(
        CLIENT_SECRET.encode('utf-8'),
        msg.encode('utf-8'),
        hashlib.sha256
    ).digest()
    return base64.b64encode(dig).decode()


# ==============================================================================
# LOGIN (via Cognito hosted UI scraping for OAuth flow)
# ==============================================================================

def handle_login(event):
    """Handle initial login with email + password.

    Strategy: Try Cognito InitiateAuth API first to detect first-time setup
    challenges (NEW_PASSWORD_REQUIRED, MFA_SETUP). If auth succeeds or
    SOFTWARE_TOKEN_MFA is required, fall through to hosted UI scraping for
    the OAuth token exchange that gives us the Open WebUI session.
    """
    try:
        body = parse_body(event)
    except (json.JSONDecodeError, TypeError) as e:
        print(f'Body parse error: {e}')
        return api_response(400, {'error': 'Invalid request body'})

    email = body.get('email', '').strip()
    password = body.get('password', '')

    if not email or not password:
        return api_response(400, {'error': 'Email and password are required'})

    # --- Phase 1: Try Cognito API to detect first-time challenges ---
    try:
        api_result = _cognito_initiate_auth(email, password)
        challenge = api_result.get('ChallengeName', '')

        if challenge == 'NEW_PASSWORD_REQUIRED':
            state = json.dumps({
                'session': api_result.get('Session', ''),
                'email': email,
                'challenge': 'NEW_PASSWORD_REQUIRED',
            })
            return api_response(200, {
                'status': 'new_password_required',
                'message': 'Please set a new password to continue.',
                'session': base64.b64encode(state.encode()).decode(),
            })

        if challenge == 'MFA_SETUP':
            # User changed password but hasn't enrolled MFA yet
            state = json.dumps({
                'session': api_result.get('Session', ''),
                'email': email,
                'challenge': 'MFA_SETUP',
            })
            return api_response(200, {
                'status': 'mfa_setup_required',
                'message': 'Please set up your authenticator app.',
                'session': base64.b64encode(state.encode()).decode(),
            })

        # If SOFTWARE_TOKEN_MFA challenge or auth succeeded, continue to
        # hosted UI scraping for the full OAuth flow (Phase 2 below)

    except Exception as e:
        error_msg = str(e)
        if 'NotAuthorizedException' in error_msg:
            return api_response(401, {'error': 'Invalid email or password'})
        if 'UserNotFoundException' in error_msg:
            return api_response(401, {'error': 'Invalid email or password'})
        # For other errors, log and fall through to hosted UI approach
        print(f'InitiateAuth pre-check failed (falling through): {error_msg}')

    # --- Phase 2: Full OAuth flow via hosted UI scraping ---
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
            # Try alternate CSRF extraction patterns for newer Cognito UI
            csrf_token = _extract_csrf_alternate(resp['body'])

        if not csrf_token:
            print('Step 3 failed: could not extract CSRF token from login page')
            print(f'Step 3 login page URL: {login_page_url}')
            print(f'Step 3 response status: {resp["status"]}')
            # Log first 500 chars of body for debugging
            print(f'Step 3 body preview: {resp["body"][:500]}')
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
            return _initiate_first_time_setup(email, password)

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


def _cognito_initiate_auth(email, password):
    """Call Cognito InitiateAuth API to validate credentials and detect challenges."""
    auth_params = {
        'USERNAME': email,
        'PASSWORD': password,
    }
    secret_hash = compute_secret_hash(email)
    if secret_hash:
        auth_params['SECRET_HASH'] = secret_hash

    return cognito_api('InitiateAuth', {
        'AuthFlow': 'USER_PASSWORD_AUTH',
        'ClientId': CLIENT_ID,
        'AuthParameters': auth_params,
    })


def _extract_csrf_alternate(html):
    """Try alternate CSRF extraction patterns for newer Cognito hosted UI."""
    if not html:
        return ''
    # Meta tag pattern
    match = re.search(r'<meta\s+name=["\']csrf-token["\']\s+content=["\']([^"\']+)["\']', html)
    if match:
        return match.group(1)
    # Hidden input with different attribute order or spacing
    match = re.search(r'name\s*=\s*["\']_csrf["\']\s*[^>]*value\s*=\s*["\']([^"\']+)["\']', html)
    if match:
        return match.group(1)
    match = re.search(r'value\s*=\s*["\']([^"\']+)["\']\s*[^>]*name\s*=\s*["\']_csrf["\']', html)
    if match:
        return match.group(1)
    return ''


def _initiate_first_time_setup(email, password):
    """Use Cognito InitiateAuth API to handle first-time login challenges."""
    try:
        auth_params = {
            'USERNAME': email,
            'PASSWORD': password,
        }
        secret_hash = compute_secret_hash(email)
        if secret_hash:
            auth_params['SECRET_HASH'] = secret_hash

        result = cognito_api('InitiateAuth', {
            'AuthFlow': 'USER_PASSWORD_AUTH',
            'ClientId': CLIENT_ID,
            'AuthParameters': auth_params,
        })

        challenge = result.get('ChallengeName', '')
        session = result.get('Session', '')

        if challenge == 'NEW_PASSWORD_REQUIRED':
            state = json.dumps({
                'session': session,
                'email': email,
                'challenge': 'NEW_PASSWORD_REQUIRED',
            })
            return api_response(200, {
                'status': 'new_password_required',
                'message': 'Please set a new password to continue.',
                'session': base64.b64encode(state.encode()).decode(),
            })

        # If no challenge (unlikely for first-time), return generic message
        return api_response(200, {
            'status': 'new_password_required',
            'message': 'Please complete your initial setup.',
            'session': base64.b64encode(json.dumps({
                'session': session,
                'email': email,
                'challenge': challenge or 'UNKNOWN',
            }).encode()).decode(),
        })

    except Exception as e:
        error_msg = str(e)
        print(f'First-time setup initiation error: {error_msg}')
        if 'NotAuthorizedException' in error_msg:
            return api_response(401, {'error': 'Invalid email or password'})
        if 'UserNotFoundException' in error_msg:
            return api_response(401, {'error': 'Invalid email or password'})
        return api_response(500, {'error': 'Failed to start setup. Please try again.'})


# ==============================================================================
# MFA VERIFICATION (via Cognito hosted UI scraping for OAuth flow)
# ==============================================================================

def handle_mfa(event):
    """Handle MFA verification with TOTP code."""
    try:
        body = parse_body(event)
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


# ==============================================================================
# FIRST-TIME PASSWORD CHANGE (Cognito API — no hosted UI)
# ==============================================================================

def handle_change_password(event):
    """Handle NEW_PASSWORD_REQUIRED challenge via Cognito API."""
    try:
        raw_body = event.get('body', '{}')
        if event.get('isBase64Encoded') and raw_body:
            raw_body = base64.b64decode(raw_body).decode('utf-8')
        body = json.loads(raw_body or '{}')
    except (json.JSONDecodeError, TypeError):
        return api_response(400, {'error': 'Invalid request body'})

    new_password = body.get('new_password', '')
    encoded_state = body.get('session', '')

    if not new_password or not encoded_state:
        return api_response(400, {'error': 'New password and session are required'})

    try:
        state = json.loads(base64.b64decode(encoded_state))
        session = state['session']
        email = state['email']
    except (json.JSONDecodeError, KeyError):
        return api_response(400, {'error': 'Session expired. Please sign in again.'})

    try:
        # Use the name from the request body, or default to the email prefix
        name = body.get('name', '').strip() or email.split('@')[0]

        challenge_responses = {
            'USERNAME': email,
            'NEW_PASSWORD': new_password,
            'userAttributes.name': name,
        }
        secret_hash = compute_secret_hash(email)
        if secret_hash:
            challenge_responses['SECRET_HASH'] = secret_hash

        result = cognito_api('RespondToAuthChallenge', {
            'ClientId': CLIENT_ID,
            'ChallengeName': 'NEW_PASSWORD_REQUIRED',
            'Session': session,
            'ChallengeResponses': challenge_responses,
        })

        # Check if next challenge is MFA_SETUP
        next_challenge = result.get('ChallengeName', '')
        new_session = result.get('Session', '')

        if next_challenge == 'MFA_SETUP':
            # Need to set up TOTP MFA
            return _initiate_mfa_setup(email, new_session)

        if next_challenge == 'SOFTWARE_TOKEN_MFA':
            # MFA already set up, need to verify
            new_state = json.dumps({
                'session': new_session,
                'email': email,
                'challenge': 'SOFTWARE_TOKEN_MFA',
            })
            return api_response(200, {
                'status': 'mfa_required',
                'message': 'Enter the 6-digit code from your authenticator app',
                'session': base64.b64encode(new_state.encode()).decode(),
                'use_api_mfa': True,
            })

        # No more challenges — auth complete (shouldn't happen with MFA required)
        if result.get('AuthenticationResult'):
            return api_response(200, {
                'status': 'setup_complete',
                'message': 'Password changed successfully. Please sign in.',
            })

        print(f'Unexpected challenge after password change: {next_challenge}')
        return api_response(500, {'error': 'Unexpected response. Please try again.'})

    except Exception as e:
        error_msg = str(e)
        print(f'Change password error: {error_msg}')
        if 'InvalidPasswordException' in error_msg:
            return api_response(400, {
                'error': 'Password does not meet requirements. Must be 12+ characters with uppercase, lowercase, numbers, and symbols.'
            })
        return api_response(500, {'error': 'Failed to change password. Please try again.'})


def _initiate_mfa_setup(email, session):
    """Associate a TOTP software token for MFA setup."""
    try:
        result = cognito_api('AssociateSoftwareToken', {
            'Session': session,
        })

        secret_code = result.get('SecretCode', '')
        new_session = result.get('Session', '')

        if not secret_code:
            return api_response(500, {'error': 'Failed to generate MFA secret'})

        # Generate otpauth URI for QR code
        qr_uri = f'otpauth://totp/OllamaWebUI:{email}?secret={secret_code}&issuer=OllamaWebUI'

        state = json.dumps({
            'session': new_session,
            'email': email,
            'challenge': 'MFA_SETUP',
        })

        return api_response(200, {
            'status': 'mfa_setup_required',
            'message': 'Scan the QR code with your authenticator app, then enter the 6-digit code.',
            'secret': secret_code,
            'qr_uri': qr_uri,
            'session': base64.b64encode(state.encode()).decode(),
        })

    except Exception as e:
        print(f'MFA setup error: {e}')
        return api_response(500, {'error': 'Failed to start MFA setup. Please try again.'})


# ==============================================================================
# FIRST-TIME MFA ENROLLMENT (Cognito API — no hosted UI)
# ==============================================================================

def handle_setup_mfa(event):
    """Verify TOTP during first-time MFA setup via Cognito API."""
    try:
        body = parse_body(event)
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
        session = state['session']
        email = state['email']
    except (json.JSONDecodeError, KeyError):
        return api_response(400, {'error': 'Session expired. Please sign in again.'})

    try:
        # Step 1: Verify the software token
        result = cognito_api('VerifySoftwareToken', {
            'Session': session,
            'UserCode': totp_code,
        })

        status = result.get('Status', '')
        new_session = result.get('Session', '')

        if status != 'SUCCESS':
            return api_response(401, {'error': 'Invalid code. Please check your authenticator app and try again.'})

        # Step 2: Complete MFA_SETUP challenge
        challenge_responses = {
            'USERNAME': email,
        }
        secret_hash = compute_secret_hash(email)
        if secret_hash:
            challenge_responses['SECRET_HASH'] = secret_hash

        result = cognito_api('RespondToAuthChallenge', {
            'ClientId': CLIENT_ID,
            'ChallengeName': 'MFA_SETUP',
            'Session': new_session,
            'ChallengeResponses': challenge_responses,
        })

        # Setup complete — user should now sign in normally
        return api_response(200, {
            'status': 'setup_complete',
            'message': 'MFA setup complete! You can now sign in.',
        })

    except Exception as e:
        error_msg = str(e)
        print(f'MFA setup verification error: {error_msg}')
        if 'EnableSoftwareTokenMFAException' in error_msg or 'CodeMismatchException' in error_msg:
            return api_response(401, {'error': 'Invalid code. Please check your authenticator app and try again.'})
        return api_response(500, {'error': 'MFA setup failed. Please try again.'})


# ==============================================================================
# FORGOT PASSWORD (Cognito API — no hosted UI)
# ==============================================================================

def handle_forgot_password(event):
    """Initiate forgot password flow via Cognito API."""
    try:
        body = parse_body(event)
    except (json.JSONDecodeError, TypeError):
        return api_response(400, {'error': 'Invalid request body'})

    email = body.get('email', '').strip()

    if not email:
        return api_response(400, {'error': 'Email is required'})

    try:
        params = {
            'ClientId': CLIENT_ID,
            'Username': email,
        }
        secret_hash = compute_secret_hash(email)
        if secret_hash:
            params['SecretHash'] = secret_hash

        cognito_api('ForgotPassword', params)

        return api_response(200, {
            'status': 'code_sent',
            'message': 'A verification code has been sent to your email.',
        })

    except Exception as e:
        error_msg = str(e)
        print(f'Forgot password error: {error_msg}')
        # Don't reveal if user exists — always show success
        if 'UserNotFoundException' in error_msg:
            return api_response(200, {
                'status': 'code_sent',
                'message': 'If an account exists with this email, a verification code has been sent.',
            })
        if 'LimitExceededException' in error_msg:
            return api_response(429, {'error': 'Too many attempts. Please try again later.'})
        return api_response(200, {
            'status': 'code_sent',
            'message': 'If an account exists with this email, a verification code has been sent.',
        })


def handle_confirm_reset(event):
    """Confirm forgot password with verification code and new password."""
    try:
        body = parse_body(event)
    except (json.JSONDecodeError, TypeError):
        return api_response(400, {'error': 'Invalid request body'})

    email = body.get('email', '').strip()
    code = body.get('code', '').strip()
    new_password = body.get('new_password', '')

    if not email or not code or not new_password:
        return api_response(400, {'error': 'Email, verification code, and new password are required'})

    try:
        params = {
            'ClientId': CLIENT_ID,
            'Username': email,
            'ConfirmationCode': code,
            'Password': new_password,
        }
        secret_hash = compute_secret_hash(email)
        if secret_hash:
            params['SecretHash'] = secret_hash

        cognito_api('ConfirmForgotPassword', params)

        return api_response(200, {
            'status': 'password_reset',
            'message': 'Password has been reset successfully. You can now sign in.',
        })

    except Exception as e:
        error_msg = str(e)
        print(f'Confirm reset error: {error_msg}')
        if 'CodeMismatchException' in error_msg:
            return api_response(401, {'error': 'Invalid verification code. Please check and try again.'})
        if 'ExpiredCodeException' in error_msg:
            return api_response(401, {'error': 'Verification code has expired. Please request a new one.'})
        if 'InvalidPasswordException' in error_msg:
            return api_response(400, {
                'error': 'Password does not meet requirements. Must be 12+ characters with uppercase, lowercase, numbers, and symbols.'
            })
        return api_response(500, {'error': 'Password reset failed. Please try again.'})


# ==============================================================================
# COGNITO API HELPER
# ==============================================================================

def cognito_api(action, params):
    """Call Cognito Identity Provider API."""
    data = json.dumps(params).encode('utf-8')
    req = urllib.request.Request(
        COGNITO_ENDPOINT,
        data=data,
        headers={
            'Content-Type': 'application/x-amz-json-1.1',
            'X-Amz-Target': f'AWSCognitoIdentityProviderService.{action}',
        },
    )

    try:
        resp = urllib.request.urlopen(req, timeout=25)
        return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode('utf-8', errors='replace')
        error_data = {}
        try:
            error_data = json.loads(error_body)
        except json.JSONDecodeError:
            pass
        error_type = error_data.get('__type', '')
        error_msg = error_data.get('message', error_data.get('Message', ''))
        raise Exception(f'{error_type}: {error_msg}')


# ==============================================================================
# OAUTH CALLBACK COMPLETION
# ==============================================================================

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
