"""
Authentication manager for the Subconscious client.

Talks to the Subconscious identity server (the FastAPI ``subconscious-server``
project) and handles the full set of auth flows used by the desktop/mobile UI:

  • Email signup   — request a verification code, confirm it, then set a password.
  • Email login    — email + password.
  • Password reset — request a code, confirm it with a new password.
  • GitHub OAuth   — native loopback flow (system browser + local callback).

Sessions (access token, refresh token, and the user summary) are persisted in
the encrypted secrets store managed by :class:`~subconscious.config.Config`, so
the user stays signed in across restarts. Access tokens are short-lived and are
transparently refreshed using the stored refresh token.

This module is intentionally UI-agnostic: it exposes coroutines that return
plain dicts (or raise :class:`AuthError`) so it can be driven from the Flet
desktop UI, the mobile UI, the TUI, or tests.
"""
from __future__ import annotations

import time
import httpx
import asyncio
import logging
import threading
import webbrowser
import http.server
from typing import Optional
from urllib.parse import urlparse, parse_qs

from .config import Config
from .constants import SERVER_URL, VERSION


# Logging and env config
logger = logging.getLogger("subconscious")

# Key under which the session is stored inside Config.secrets
_SECRETS_KEY = "auth"
# Refresh the access token this many seconds before it actually expires
_REFRESH_SKEW = 30
# Cookie name the server uses for the refresh token
_REFRESH_COOKIE = "sc_refresh"


class AuthError(Exception):
  """Raised when an auth operation fails. ``message`` is safe to show users."""

  def __init__(self, message: str, status: Optional[int] = None):
    super().__init__(message)
    self.message = message
    self.status = status


class AuthManager:
  """Manages authentication state and server communication for one client."""

  def __init__(self, config: Config, base_url: str = SERVER_URL):
    self.config = config
    self.base_url = base_url.rstrip("/")
    # In-memory session mirror of what's stored in the encrypted secrets file.
    self._session: dict = {}
    # Guards token refresh so concurrent requests don't refresh in parallel.
    self._refresh_lock = asyncio.Lock()

  # ──────────────────────────────────────────────────────────────────────────
  # Session persistence
  # ──────────────────────────────────────────────────────────────────────────

  def load_session(self) -> None:
    """Load any persisted session from the encrypted secrets store."""
    self.config.read_keyring()
    self._session = (self.config.secrets or {}).get(_SECRETS_KEY, {}) or {}

  async def _save_session(self, data: dict) -> None:
    """Persist the current session to the encrypted secrets store."""
    self.config.read_keyring()
    if self.config.secrets is None:
      self.config.secrets = {}
    self.config.secrets[_SECRETS_KEY] = data
    self._session = data
    await self.config.write_keyring()

  async def clear_session(self) -> None:
    """Forget the local session (used on logout)."""
    await self._save_session({})

  # ──────────────────────────────────────────────────────────────────────────
  # Public state helpers
  # ──────────────────────────────────────────────────────────────────────────

  @property
  def is_authenticated(self) -> bool:
    return bool(self._session.get("refresh_token") or self._session.get("access_token"))

  @property
  def current_user(self) -> Optional[dict]:
    return self._session.get("user")

  # ──────────────────────────────────────────────────────────────────────────
  # Low-level HTTP helpers
  # ──────────────────────────────────────────────────────────────────────────

  def _client(self, **kwargs) -> httpx.AsyncClient:
    headers = {"User-Agent": f"Subconscious/{VERSION}"}
    return httpx.AsyncClient(
      base_url=self.base_url,
      headers=headers,
      timeout=kwargs.pop("timeout", 30),
      **kwargs,
    )

  @staticmethod
  def _detail(resp: httpx.Response, fallback: str) -> str:
    """Extract a human-readable error message from a server error response."""
    try:
      body = resp.json()
      detail = body.get("detail")
      if isinstance(detail, str):
        return detail
      if isinstance(detail, list) and detail:
        # FastAPI validation errors
        msg = detail[0].get("msg")
        if msg:
          return msg
    except Exception:
      pass
    return fallback

  async def _store_auth_response(self, data: dict) -> dict:
    """Persist an AuthResponse payload returned by the server."""
    expires_in = int(data.get("expires_in", 0))
    session = {
      "access_token": data.get("access_token"),
      "refresh_token": data.get("refresh_token"),
      "expires_at": time.time() + expires_in if expires_in else 0,
      "user": data.get("user"),
    }
    await self._save_session(session)
    return session["user"] or {}

  # ──────────────────────────────────────────────────────────────────────────
  # Token refresh + authenticated requests
  # ──────────────────────────────────────────────────────────────────────────

  async def _refresh_access_token(self) -> bool:
    """Use the stored refresh token to obtain a new access token.

    Returns True on success. On failure the local session is cleared.
    """
    refresh_token = self._session.get("refresh_token")
    if not refresh_token:
      return False

    async with self._refresh_lock:
      # Another coroutine may have refreshed while we waited for the lock.
      if self._session.get("access_token") and not self._access_token_expired():
        return True
      try:
        async with self._client() as client:
          resp = await client.post(
            "/auth/refresh",
            cookies={_REFRESH_COOKIE: refresh_token},
          )
      except httpx.HTTPError as exc:
        logger.warning(f"Token refresh request failed: {exc}")
        return False

      if resp.status_code != 200:
        logger.info("Refresh token rejected; clearing session.")
        await self.clear_session()
        return False

      body = resp.json()
      new_refresh = resp.cookies.get(_REFRESH_COOKIE) or refresh_token
      expires_in = int(body.get("expires_in", 0))
      session = dict(self._session)
      session["access_token"] = body.get("access_token")
      session["refresh_token"] = new_refresh
      session["expires_at"] = time.time() + expires_in if expires_in else 0
      await self._save_session(session)
      return True

  def _access_token_expired(self) -> bool:
    expires_at = self._session.get("expires_at", 0)
    if not expires_at:
      return True
    return time.time() >= (expires_at - _REFRESH_SKEW)

  async def _valid_access_token(self) -> Optional[str]:
    """Return a non-expired access token, refreshing if necessary."""
    if self._session.get("access_token") and not self._access_token_expired():
      return self._session["access_token"]
    if await self._refresh_access_token():
      return self._session.get("access_token")
    return None

  async def authed_request(self, method: str, path: str, **kwargs) -> httpx.Response:
    """Perform a request with the bearer token attached, auto-refreshing once
    on a 401. Raises :class:`AuthError` if no valid session is available.
    """
    token = await self._valid_access_token()
    if not token:
      raise AuthError("Not signed in.", status=401)

    headers = {**kwargs.pop("headers", {}), "Authorization": f"Bearer {token}"}
    async with self._client() as client:
      resp = await client.request(method, path, headers=headers, **kwargs)
      if resp.status_code == 401 and await self._refresh_access_token():
        headers["Authorization"] = f"Bearer {self._session['access_token']}"
        resp = await client.request(method, path, headers=headers, **kwargs)
    return resp

  # ──────────────────────────────────────────────────────────────────────────
  # Email signup flow
  # ──────────────────────────────────────────────────────────────────────────

  async def register_email(self, email: str) -> None:
    """Step 1 of signup: ask the server to email a verification code."""
    email = (email or "").strip()
    if not email:
      raise AuthError("Enter an email address.")
    try:
      async with self._client() as client:
        resp = await client.post("/auth/email/register", json={"email": email})
    except httpx.HTTPError as exc:
      raise AuthError(f"Could not reach the server: {exc}") from exc
    if resp.status_code not in (200, 202):
      raise AuthError(self._detail(resp, "Could not start signup."), status=resp.status_code)

  async def verify_email(self, email: str, code: str) -> str:
    """Step 2 of signup: confirm the code, returning a verification token."""
    try:
      async with self._client() as client:
        resp = await client.post(
          "/auth/email/verify",
          json={"email": email.strip(), "code": code.strip()},
        )
    except httpx.HTTPError as exc:
      raise AuthError(f"Could not reach the server: {exc}") from exc
    if resp.status_code != 200:
      raise AuthError(self._detail(resp, "Invalid or expired code."), status=resp.status_code)
    return resp.json()["verification_token"]

  async def complete_signup(
    self, verification_token: str, password: str, display_name: Optional[str] = None
  ) -> dict:
    """Step 3 of signup: set the password and sign in."""
    if len(password) < 8:
      raise AuthError("Password must be at least 8 characters.")
    payload = {"verification_token": verification_token, "password": password}
    if display_name:
      payload["display_name"] = display_name
    try:
      async with self._client() as client:
        resp = await client.post(
          "/auth/email/complete", params={"native": "true"}, json=payload
        )
    except httpx.HTTPError as exc:
      raise AuthError(f"Could not reach the server: {exc}") from exc
    if resp.status_code != 200:
      raise AuthError(self._detail(resp, "Could not complete signup."), status=resp.status_code)
    return await self._store_auth_response(resp.json())

  # ──────────────────────────────────────────────────────────────────────────
  # Email login
  # ──────────────────────────────────────────────────────────────────────────

  async def login_email(self, email: str, password: str) -> dict:
    """Sign in with email and password."""
    if not email.strip() or not password:
      raise AuthError("Enter your email and password.")
    try:
      async with self._client() as client:
        resp = await client.post(
          "/auth/email/login",
          params={"native": "true"},
          json={"email": email.strip(), "password": password},
        )
    except httpx.HTTPError as exc:
      raise AuthError(f"Could not reach the server: {exc}") from exc
    if resp.status_code != 200:
      raise AuthError(self._detail(resp, "Invalid email or password."), status=resp.status_code)
    return await self._store_auth_response(resp.json())

  # ──────────────────────────────────────────────────────────────────────────
  # Password reset
  # ──────────────────────────────────────────────────────────────────────────

  async def request_password_reset(self, email: str) -> None:
    """Ask the server to email a password-reset code."""
    if not email.strip():
      raise AuthError("Enter your email address.")
    try:
      async with self._client() as client:
        resp = await client.post("/auth/password-reset/request", json={"email": email.strip()})
    except httpx.HTTPError as exc:
      raise AuthError(f"Could not reach the server: {exc}") from exc
    if resp.status_code not in (200, 202):
      raise AuthError(self._detail(resp, "Could not start password reset."), status=resp.status_code)

  async def confirm_password_reset(self, email: str, code: str, new_password: str) -> dict:
    """Confirm a reset code and set a new password, signing in on success."""
    if len(new_password) < 8:
      raise AuthError("Password must be at least 8 characters.")
    try:
      async with self._client() as client:
        resp = await client.post(
          "/auth/password-reset/confirm",
          params={"native": "true"},
          json={"email": email.strip(), "code": code.strip(), "new_password": new_password},
        )
    except httpx.HTTPError as exc:
      raise AuthError(f"Could not reach the server: {exc}") from exc
    if resp.status_code != 200:
      raise AuthError(self._detail(resp, "Could not reset password."), status=resp.status_code)
    return await self._store_auth_response(resp.json())

  # ──────────────────────────────────────────────────────────────────────────
  # GitHub OAuth (native loopback flow)
  # ──────────────────────────────────────────────────────────────────────────

  async def login_oauth(self, slug: str = "github", timeout: float = 300.0) -> dict:
    """Run a native OAuth login via the system browser and a loopback server.

    Opens the provider's consent screen in the user's browser. After the
    server completes the code exchange it redirects to a short-lived local
    HTTP server which captures the issued tokens.
    """
    loop = asyncio.get_running_loop()
    result_future: asyncio.Future = loop.create_future()

    httpd, port = _start_loopback_server(loop, result_future)
    redirect_to = f"http://127.0.0.1:{port}/callback"
    try:
      # 1. Ask the server for the authorization URL bound to our loopback.
      try:
        async with self._client() as client:
          resp = await client.get(
            f"/auth/{slug}/login",
            params={"native": "true", "redirect_to": redirect_to},
          )
      except httpx.HTTPError as exc:
        raise AuthError(f"Could not reach the server: {exc}") from exc
      if resp.status_code != 200:
        raise AuthError(
          self._detail(resp, f"{slug} login is not available."), status=resp.status_code
        )
      auth_url = resp.json()["url"]

      # 2. Hand off to the system browser.
      if not webbrowser.open(auth_url):
        raise AuthError("Could not open a browser for sign-in.")

      # 3. Wait for the loopback server to capture the redirect.
      try:
        params = await asyncio.wait_for(result_future, timeout=timeout)
      except asyncio.TimeoutError:
        raise AuthError("Sign-in timed out. Please try again.")

      if "error" in params:
        raise AuthError(f"Sign-in failed: {params['error']}")
      if "access_token" not in params:
        raise AuthError("Sign-in did not complete.")

      expires_in = int(params.get("expires_in", 0))
      session = {
        "access_token": params.get("access_token"),
        "refresh_token": params.get("refresh_token"),
        "expires_at": time.time() + expires_in if expires_in else 0,
        "user": None,
      }
      await self._save_session(session)
      # Fetch the full user profile now that we have a token.
      try:
        user = await self.fetch_me()
        if user:
          session["user"] = user
          await self._save_session(session)
      except AuthError:
        pass
      return session.get("user") or {}
    finally:
      httpd.shutdown()
      httpd.server_close()

  # ──────────────────────────────────────────────────────────────────────────
  # Session info / logout
  # ──────────────────────────────────────────────────────────────────────────

  async def fetch_me(self) -> Optional[dict]:
    """Fetch the current user summary from the server and cache it."""
    resp = await self.authed_request("GET", "/auth/me")
    if resp.status_code != 200:
      raise AuthError(self._detail(resp, "Could not load your account."), status=resp.status_code)
    user = resp.json()
    session = dict(self._session)
    session["user"] = user
    await self._save_session(session)
    return user

  async def logout(self) -> None:
    """Revoke the refresh token server-side (best effort) and clear locally."""
    refresh_token = self._session.get("refresh_token")
    if refresh_token:
      try:
        async with self._client() as client:
          await client.post("/auth/logout", cookies={_REFRESH_COOKIE: refresh_token})
      except httpx.HTTPError as exc:
        logger.debug(f"Server logout failed (ignored): {exc}")
    await self.clear_session()


# ──────────────────────────────────────────────────────────────────────────────
# Loopback HTTP server for the native OAuth redirect
# ──────────────────────────────────────────────────────────────────────────────

_SUCCESS_PAGE = (
  b"<!doctype html><html><head><meta charset='utf-8'>"
  b"<title>Subconscious</title></head>"
  b"<body style='font-family:sans-serif;text-align:center;margin-top:15%'>"
  b"<h2>You're signed in.</h2>"
  b"<p>You can close this tab and return to Subconscious.</p>"
  b"</body></html>"
)


def _start_loopback_server(
  loop: asyncio.AbstractEventLoop, future: asyncio.Future
) -> tuple[http.server.HTTPServer, int]:
  """Start a one-shot loopback HTTP server that resolves *future* with the
  query parameters of the first request it receives, then keeps serving the
  success page. Returns (server, port). The server runs in a daemon thread.
  """

  class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
      parsed = urlparse(self.path)
      # Flatten single-value query params.
      params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
      if not future.done():
        loop.call_soon_threadsafe(future.set_result, params)
      self.send_response(200)
      self.send_header("Content-Type", "text/html; charset=utf-8")
      self.end_headers()
      self.wfile.write(_SUCCESS_PAGE)

    def log_message(self, *args):  # silence default stderr logging
      pass

  httpd = http.server.HTTPServer(("127.0.0.1", 0), _Handler)
  port = httpd.server_address[1]
  thread = threading.Thread(target=httpd.serve_forever, daemon=True)
  thread.start()
  return httpd, port
