"""Role based authorisation for remote peers (webrtc.md 6.2). Default deny."""

from __future__ import annotations

import re
from collections.abc import Iterable

THIN_CLIENT = "thin_client"
HIVE_PEER = "hive_peer"
ROLES = frozenset({THIN_CLIENT, HIVE_PEER})

_UUID = r"[^/]+"


def _rule(method: str, pattern: str) -> tuple[str, re.Pattern[str]]:
    return method, re.compile(pattern)


# Routes both roles may call. Everything else (account, settings,
# model-configurations, tool-registry, rag, workspace files, workspace writes,
# the SSE stream and the hive management routes) is denied.
_COMMON_HTTP_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    _rule("GET", r"/api/v1/health"),
    _rule("GET", r"/api/v1/workspaces"),
    _rule("GET", rf"/api/v1/workspaces/{_UUID}"),
    _rule("GET", rf"/api/v1/workspaces/{_UUID}/threads"),
    _rule("POST", r"/api/v1/threads"),
    _rule("GET", rf"/api/v1/threads/{_UUID}"),
    _rule("GET", rf"/api/v1/threads/{_UUID}/messages"),
    _rule("POST", r"/api/v1/messages"),
    _rule("GET", r"/api/v1/models"),
    _rule("GET", r"/api/v1/hive/tasks"),
)

_HTTP_RULES: dict[str, tuple[tuple[str, re.Pattern[str]], ...]] = {
    THIN_CLIENT: _COMMON_HTTP_RULES,
    HIVE_PEER: _COMMON_HTTP_RULES,
}

_COMMON_FRAMES = frozenset(
    {
        "client.hello",
        "ping",
        "chat.send",
        "chat.cancel",
        "tool.approval.response",
        "client.tool.result",
        "tool.register",
        "tool.unregister",
        "profile.set",
        # Phase 4: both roles may submit/cancel tasks and watch threads.
        "task.submit",
        "task.cancel",
        "thread.subscribe",
        "thread.unsubscribe",
    }
)
# Phase 5 remote tools: tool.list/tool.call/tool.cancel (and their results) are hive_peer only.
REMOTE_TOOL_FRAMES = frozenset(
    {"tool.list", "tool.list.result", "tool.call", "tool.result", "tool.cancel"}
)
_PEER_ONLY_FRAMES = frozenset({"chat.notification"}) | REMOTE_TOOL_FRAMES
_FRAMES: dict[str, frozenset[str]] = {
    THIN_CLIENT: _COMMON_FRAMES,
    HIVE_PEER: _COMMON_FRAMES | _PEER_ONLY_FRAMES,
}
# Whole families that only a hive peer may use (Phase 4+ frames).
_PEER_ONLY_PREFIXES = ("sync.", "task.", "tool.call", "tool.result", "tool.list", "tool.cancel")
# ``task.*`` stays peer-only except for the explicit client frames in _COMMON_FRAMES.
_TASK_CLIENT_FRAMES = frozenset({"task.submit", "task.cancel"})


def role_for_kind(kind: str) -> str | None:
    """Map a directory node kind to its role (``engine`` is a full node)."""
    return {"engine": HIVE_PEER, "thin": THIN_CLIENT}.get(kind)


def normalise_path(path: str) -> str | None:
    """Reject anything that could escape the allowlist via path tricks."""
    if (
        not path.startswith("/")
        or "\\" in path
        or "\x00" in path
        or "//" in path
        or "%" in path
        or any(part in {".", ".."} for part in path.split("/"))
    ):
        return None
    return path.rstrip("/") or "/"


def authorize_http(role: str, method: str, path: str) -> bool:
    rules = _HTTP_RULES.get(role)
    clean = normalise_path(path)
    if rules is None or clean is None:
        return False
    method = method.upper()
    return any(m == method and p.fullmatch(clean) for m, p in rules)


def authorize_frame(role: str, frame_type: str) -> bool:
    allowed = _FRAMES.get(role)
    if allowed is None or not isinstance(frame_type, str):
        return False
    if frame_type in _TASK_CLIENT_FRAMES:
        return frame_type in allowed
    if frame_type.startswith(_PEER_ONLY_PREFIXES):
        return role == HIVE_PEER
    return frame_type in allowed


def allowed_http_rules(role: str) -> Iterable[tuple[str, str]]:
    return [(m, p.pattern) for m, p in _HTTP_RULES.get(role, ())]
