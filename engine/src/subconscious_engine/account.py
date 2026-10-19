"""Cloud account sessions owned exclusively by the local engine."""

import asyncio
from collections.abc import Callable
from dataclasses import dataclass
import logging
from typing import Any, Protocol
from urllib.parse import urlsplit

import time
import httpx
import keyring
from keyring.errors import PasswordDeleteError

from subconscious_engine.configuration import EncryptedModelConfigurationStore
from subconscious_engine.http_log import format_body, safe_url, verbose_enabled
from subconscious_engine.configuration.key_provider import (
    SERVICE_NAME as _ENCRYPTION_KEYRING_SERVICE,
)
_LOG = logging.getLogger(__name__)

DEFAULT_ACCOUNT_SERVER_URL = "https://api.subconscious.chat"
_LOGGER = logging.getLogger("uvicorn.error")
# Windows Generic Credentials are uniquely addressed by TargetName (the
# keyring service), not by the username. Keep account refresh tokens on a
# separate target so they cannot replace the Fernet encryption key.
_KEYRING_SERVICE = "subconscious.account.refresh-token.v1"
_KEYRING_USER = "refresh_token"

if _KEYRING_SERVICE == _ENCRYPTION_KEYRING_SERVICE:
    raise RuntimeError("Account and encryption credentials must use distinct keyring services.")


class AccountError(Exception):
    """A safe account error that may be returned through the local API."""

    def __init__(self, message: str, status_code: int = 502) -> None:
        super().__init__(message)
        self.message = message
        self.status_code = status_code


@dataclass(frozen=True, slots=True)
class AccountUser:
    id: str
    email: str
    connected_providers: tuple[str, ...]
    display_name: str | None = None
    avatar_url: str | None = None

    @classmethod
    def from_json(cls, value: dict[str, Any]) -> "AccountUser":
        return cls(
            id=_required_text(value, "id"),
            email=_required_text(value, "email"),
            display_name=_optional_text(value, "display_name", "displayName"),
            avatar_url=_optional_text(value, "avatar_url", "avatarUrl"),
            connected_providers=tuple(
                item
                for item in value.get("connected_providers", [])
                if isinstance(item, str)
            ),
        )

    def to_api(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "email": self.email,
            "display_name": self.display_name,
            "avatar_url": self.avatar_url,
            "connected_providers": list(self.connected_providers),
        }


class RefreshTokenStore(Protocol):
    def read(self) -> str | None: ...
    def write(self, token: str) -> None: ...
    def delete(self) -> None: ...


class KeyringRefreshTokenStore:
    """Keeps the cloud refresh token in the current user's OS keyring.

    ``namespace`` separates profiles; ``None`` keeps the original (default profile) entry.
    """

    def __init__(self, namespace: str | None = None) -> None:
        self._user = _KEYRING_USER if not namespace else f"{_KEYRING_USER}:{namespace}"

    def read(self) -> str | None:
        try:
            token = keyring.get_password(_KEYRING_SERVICE, self._user)
        except Exception as error:
            raise AccountError(
                "The engine could not access the saved account session."
            ) from error
        return token.strip() if token and token.strip() else None

    def write(self, token: str) -> None:
        try:
            keyring.set_password(_KEYRING_SERVICE, self._user, token)
        except Exception as error:
            raise AccountError(
                "The engine could not save the account session."
            ) from error

    def delete(self) -> None:
        try:
            keyring.delete_password(_KEYRING_SERVICE, self._user)
        except PasswordDeleteError:
            # There is no local session to clear.
            _LOG.warning("account.KeyringRefreshTokenStore.delete: handled PasswordDeleteError; continuing with fallback", exc_info=True)
            pass
        except Exception as error:
            raise AccountError(
                "The engine could not clear the saved account session."
            ) from error


class EncryptedRefreshTokenStore:
    """Secure fallback using the engine's existing Fernet-encrypted vault."""

    def __init__(self, credential_store: EncryptedModelConfigurationStore) -> None:
        self._credential_store = credential_store

    def read(self) -> str | None:
        try:
            return self._credential_store.get_account_refresh_token()
        except Exception as error:
            raise AccountError(
                "The engine could not access the encrypted account session."
            ) from error

    def write(self, token: str) -> None:
        try:
            self._credential_store.set_account_refresh_token(token)
        except Exception as error:
            raise AccountError(
                "The engine could not save the encrypted account session."
            ) from error

    def delete(self) -> None:
        try:
            self._credential_store.remove_account_refresh_token()
        except Exception as error:
            raise AccountError(
                "The engine could not clear the encrypted account session."
            ) from error


class ResilientRefreshTokenStore:
    """Prefer OS credentials while retaining a secure encrypted fallback."""

    def __init__(
        self, primary: RefreshTokenStore, fallback: RefreshTokenStore
    ) -> None:
        self._primary = primary
        self._fallback = fallback

    def read(self) -> str | None:
        try:
            fallback_token = self._fallback.read()
        except AccountError:
            _LOG.warning("account.ResilientRefreshTokenStore.read: handled AccountError; continuing with fallback", exc_info=True)
            fallback_token = None
        return fallback_token or self._primary.read()

    def write(self, token: str) -> None:
        try:
            self._primary.write(token)
        except AccountError:
            if not getattr(self, "_warned_write", False):
                self._warned_write = True
                _LOG.warning("Keyring write failed; using the encrypted fallback store.")
            else:
                _LOG.debug("Keyring write failed again; using the fallback.", exc_info=True)
            self._fallback.write(token)
        else:
            try:
                self._fallback.delete()
            except AccountError:
                # A stale fallback does not invalidate the keyring-backed session.
                _LOG.warning("account.ResilientRefreshTokenStore.write: handled AccountError; continuing with fallback", exc_info=True)
                pass

    def delete(self) -> None:
        errors: list[AccountError] = []
        for store in (self._fallback, self._primary):
            try:
                store.delete()
            except AccountError as error:
                _LOG.warning("account.ResilientRefreshTokenStore.delete: handled AccountError; continuing with fallback", exc_info=True)
                errors.append(error)
        if len(errors) == 2:
            raise errors[0]


class AccountServerClient:
    def __init__(self, base_url: str, client: httpx.AsyncClient | None = None) -> None:
        parsed = urlsplit(base_url.strip())
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("SUBCONSCIOUS_SERVER_URL must be an HTTP(S) URL.")
        self._base_url = base_url.rstrip("/") + "/"
        self._client = client or httpx.AsyncClient(
            base_url=self._base_url, timeout=15.0
        )

    @property
    def base_url(self) -> str:
        return self._base_url

    async def close(self) -> None:
        await self._client.aclose()

    async def login(self, email: str, password: str) -> tuple[str, str, AccountUser]:
        value = await self._request(
            "POST",
            "auth/email/login?native=true",
            {"email": email, "password": password},
        )
        return _auth_session(value)

    async def register(self, email: str) -> str:
        value = await self._request("POST", "auth/email/register", {"email": email})
        return (
            _optional_text(value, "message")
            or "Check your email for a verification code."
        )

    async def complete_signup(
        self, email: str, code: str, password: str, display_name: str | None
    ) -> tuple[str, str, AccountUser]:
        verified = await self._request(
            "POST", "auth/email/verify", {"email": email, "code": code}
        )
        body: dict[str, Any] = {
            "verification_token": _required_text(verified, "verification_token"),
            "password": password,
        }
        if display_name and display_name.strip():
            body["display_name"] = display_name.strip()
        value = await self._request("POST", "auth/email/complete?native=true", body)
        return _auth_session(value)

    async def refresh(self, refresh_token: str) -> tuple[str, str]:
        value = await self._request(
            "POST", "auth/refresh", {"refresh_token": refresh_token}
        )
        return _required_text(value, "access_token"), _required_text(
            value, "refresh_token"
        )

    async def current_user(self, access_token: str) -> AccountUser:
        return AccountUser.from_json(
            await self._request("GET", "auth/me", access_token=access_token)
        )

    async def logout(self, refresh_token: str) -> None:
        await self._request("POST", "auth/logout", {"refresh_token": refresh_token})

    async def _request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        *,
        access_token: str | None = None,
    ) -> dict[str, Any]:
        headers = {"Accept": "application/json"}
        if access_token:
            headers["Authorization"] = f"Bearer {access_token}"
        url = safe_url(self._base_url + path)
        started = time.monotonic()
        try:
            response = await self._client.request(
                method, path, json=body, headers=headers
            )
        except httpx.HTTPError as error:
            _LOG.warning(
                "account.request method=%s url=%s failed elapsed_ms=%d reason=%s",
                method, url, int((time.monotonic() - started) * 1000), type(error).__name__,
            )
            _LOGGER.debug(
                "Account server request failed: method=%s path=%s reason=%s",
                method,
                path,
                error,
                exc_info=True,
            )
            raise AccountError("Could not reach the account server.") from error
        _LOG.info(
            "account.request method=%s url=%s status=%s elapsed_ms=%d",
            method, url, response.status_code, int((time.monotonic() - started) * 1000),
        )
        if verbose_enabled() and body is not None:
            _LOG.info("account.request body=%s", format_body(body))
        if response.is_error:
            message = _error_message(response)
            _LOG.warning(
                "account.request rejected method=%s url=%s status=%s detail=%s",
                method, url, response.status_code, message,
            )
            _LOGGER.debug(
                "Account server rejected request: method=%s path=%s status=%s reason=%s",
                method,
                path,
                response.status_code,
                message,
            )
            raise AccountError(message, response.status_code)
        try:
            value = response.json()
        except ValueError as error:
            raise AccountError(
                "The account server returned an invalid response."
            ) from error
        if not isinstance(value, dict):
            raise AccountError("The account server returned an invalid response.")
        return value


class AccountSessionService:
    def __init__(
        self,
        server: AccountServerClient,
        store: RefreshTokenStore | None = None,
        credential_store: EncryptedModelConfigurationStore | None = None,
        keyring_namespace: str | None = None,
    ) -> None:
        self._server = server
        self._store = store or (
            ResilientRefreshTokenStore(
                KeyringRefreshTokenStore(keyring_namespace),
                EncryptedRefreshTokenStore(credential_store),
            )
            if credential_store is not None
            else KeyringRefreshTokenStore(keyring_namespace)
        )
        self._refresh_token: str | None = None
        self._access_token: str | None = None
        self._user: AccountUser | None = None
        self._listeners: list[Callable[[AccountUser | None], None]] = []
        self._lock = asyncio.Lock()

    def subscribe(
        self, listener: Callable[[AccountUser | None], None]
    ) -> Callable[[], None]:
        """Be told (synchronously) when the signed-in user changes or signs out."""
        self._listeners.append(listener)

        def unsubscribe() -> None:
            if listener in self._listeners:
                self._listeners.remove(listener)

        return unsubscribe

    @property
    def current_account_user(self) -> AccountUser | None:
        return self._user

    def _set_user(self, user: AccountUser | None) -> None:
        previous = self._user
        self._user = user
        if (previous.id if previous else None) != (user.id if user else None):
            for listener in tuple(self._listeners):
                try:
                    listener(user)
                except Exception:  # listeners must never break account flows
                    _LOGGER.debug("Account listener failed.", exc_info=True)

    async def close(self) -> None:
        await self._server.close()

    async def restore(self) -> AccountUser | None:
        async with self._lock:
            refresh_token = self._refresh_token or self._store.read()
            if not refresh_token:
                return None
            self._refresh_token = refresh_token
            try:
                return await self._refresh_user()
            except AccountError as error:
                if error.status_code in {401, 403}:
                    self._clear_local_session()
                    return None
                raise

    async def login(self, email: str, password: str) -> AccountUser:
        async with self._lock:
            access_token, refresh_token, user = await self._server.login(
                email, password
            )
            self._set_session(access_token, refresh_token)
            self._set_user(user)
            return user

    def access_token(self) -> str | None:
        """Current access token for in-process server clients; never exposed over HTTP."""
        return self._access_token

    @property
    def server_base_url(self) -> str:
        return self._server.base_url

    async def refresh_access_token(self) -> str | None:
        """Rotate tokens and return the new access token (None when logged out)."""
        async with self._lock:
            if self._refresh_token is None:
                return None
            await self._refresh_user()
            return self._access_token

    async def request_signup_code(self, email: str) -> str:
        return await self._server.register(email)

    async def complete_signup(
        self, email: str, code: str, password: str, display_name: str | None
    ) -> AccountUser:
        async with self._lock:
            access_token, refresh_token, user = await self._server.complete_signup(
                email, code, password, display_name
            )
            self._set_session(access_token, refresh_token)
            self._set_user(user)
            return user

    async def logout(self) -> None:
        async with self._lock:
            refresh_token = self._refresh_token or self._store.read()
            self._clear_local_session()
            if not refresh_token:
                return
            try:
                await self._server.logout(refresh_token)
            except AccountError:
                # The local credential is already gone, so the server session will expire.
                _LOG.warning("account.AccountSessionService.logout: handled AccountError; continuing with fallback", exc_info=True)
                pass

    async def _refresh_user(self) -> AccountUser:
        assert self._refresh_token is not None
        access_token, refresh_token = await self._server.refresh(self._refresh_token)
        self._set_session(access_token, refresh_token)
        user = await self._server.current_user(access_token)
        self._set_user(user)
        return user

    def _set_session(self, access_token: str, refresh_token: str) -> None:
        self._store.write(refresh_token)
        self._access_token = access_token
        self._refresh_token = refresh_token

    def _clear_local_session(self) -> None:
        self._access_token = None
        self._refresh_token = None
        self._set_user(None)
        self._store.delete()


def _required_text(value: dict[str, Any], key: str) -> str:
    result = value.get(key)
    if isinstance(result, str) and result.strip():
        return result
    raise AccountError("The account server returned an invalid response.")


def _optional_text(value: dict[str, Any], *keys: str) -> str | None:
    for key in keys:
        result = value.get(key)
        if isinstance(result, str):
            return result
    return None


def _auth_session(value: dict[str, Any]) -> tuple[str, str, AccountUser]:
    user = value.get("user")
    if not isinstance(user, dict):
        raise AccountError("The account server returned an invalid response.")
    return (
        _required_text(value, "access_token"),
        _required_text(value, "refresh_token"),
        AccountUser.from_json(user),
    )


def _error_message(response: httpx.Response) -> str:
    try:
        value = response.json()
    except ValueError:
        _LOG.warning("account._error_message: handled ValueError; continuing with fallback", exc_info=True)
        value = None
    if isinstance(value, dict):
        for key in ("message", "error", "detail"):
            message = value.get(key)
            if isinstance(message, str) and message.strip():
                return message.strip()
    if response.status_code == 401:
        return "The email address or password is incorrect."
    if response.status_code == 429:
        return "Too many account requests. Please try again shortly."
    return "The account server could not complete the request."
