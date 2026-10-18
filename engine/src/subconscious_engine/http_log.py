"""Secret-free helpers for logging outbound account-server requests."""
import os
from typing import Any
from urllib.parse import urlsplit

_SECRET_KEYS = (
    "password", "token", "code", "secret", "credential", "signature",
    "seed", "private", "ticket", "challenge", "verifier",
)
BODY_LIMIT = 2048


def verbose_enabled() -> bool:
    return os.environ.get("SUBCONSCIOUS_HTTP_LOG", "").strip().lower() == "verbose"


def safe_url(url: str) -> str:
    """Scheme, host and path only; query values can carry secrets."""
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}{parts.path}"


def redact_json(value: Any) -> Any:
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key, item in value.items():
            lowered = str(key).lower()
            if any(part in lowered for part in _SECRET_KEYS):
                out[key] = f"<redacted len={len(str(item))}>"
            elif lowered == "email" and isinstance(item, str) and "@" in item:
                name, _, domain = item.partition("@")
                out[key] = f"{name[:1]}***@{domain}"
            else:
                out[key] = redact_json(item)
        return out
    if isinstance(value, list):
        return [redact_json(item) for item in value]
    return value


def format_body(value: Any) -> str:
    text = str(redact_json(value))
    if len(text) <= BODY_LIMIT:
        return text
    return f"{text[:BODY_LIMIT]}...(truncated {len(text) - BODY_LIMIT} chars)"
