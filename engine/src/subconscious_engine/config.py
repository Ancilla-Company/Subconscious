"""Engine startup configuration matching the .NET composition root"""

import os
import sys
from pathlib import Path
from dataclasses import dataclass


REMOTE_TOOL_MODES = ("off", "ask", "allow")


@dataclass(frozen=True, slots=True)
class RemoteToolsConfig:
    """What this node lets its hive peers run (webrtc.md section 8). Everything is off by default.

    ``tools`` maps a built-in tool name to ``off``, ``ask`` or ``allow``; names that are
    missing are ``off``. ``filesystem_roots`` scopes the filesystem tools: with no roots
    they cannot be exported at all.
    """

    tools: tuple[tuple[str, str], ...] = ()
    filesystem_roots: tuple[str, ...] = ()
    call_timeout_seconds: float = 60.0
    max_result_bytes: int = 256 * 1024
    max_concurrent_calls: int = 4
    approval_timeout_seconds: float = 60.0

    def modes(self) -> dict[str, str]:
        return dict(self.tools)

    def to_mapping(self) -> dict[str, object]:
        return {
            "tools": dict(self.tools),
            "filesystem_roots": list(self.filesystem_roots),
            "call_timeout_seconds": self.call_timeout_seconds,
            "max_result_bytes": self.max_result_bytes,
            "max_concurrent_calls": self.max_concurrent_calls,
            "approval_timeout_seconds": self.approval_timeout_seconds,
        }


REMOTE_TOOLS_KEYS = frozenset(RemoteToolsConfig.__dataclass_fields__)
MAX_REMOTE_RESULT_BYTES = 8 * 1024 * 1024


def remote_tools_from_mapping(
    value: object, base: RemoteToolsConfig | None = None
) -> RemoteToolsConfig:
    """Validate a ``remote_tools`` mapping (strict) and overlay it on ``base``.

    Raises ``ValueError`` with a user presentable message. Unknown keys are errors.
    """
    current = base or RemoteToolsConfig()
    if value is None:
        return current
    if not isinstance(value, dict):
        raise ValueError("remote_tools must be a mapping.")
    unknown = sorted(set(value) - REMOTE_TOOLS_KEYS)
    if unknown:
        raise ValueError(f"Unknown remote_tools keys: {', '.join(map(str, unknown))}.")
    tools, roots = current.tools, current.filesystem_roots
    if "tools" in value:
        raw = value["tools"]
        if raw is None:
            raw = {}
        if not isinstance(raw, dict):
            raise ValueError("remote_tools.tools must be a mapping of tool name to mode.")
        for name, mode in raw.items():
            if not isinstance(name, str) or not name or len(name) > 100:
                raise ValueError("remote_tools.tools names must be non-empty strings.")
            if mode not in REMOTE_TOOL_MODES:
                raise ValueError(f"remote_tools.tools.{name} must be one of off, ask or allow.")
        tools = tuple(sorted(raw.items()))
    if "filesystem_roots" in value:
        raw_roots = value["filesystem_roots"]
        if raw_roots is None:
            raw_roots = []
        if not isinstance(raw_roots, list) or not all(
            isinstance(item, str) and item.strip() and "\x00" not in item for item in raw_roots
        ):
            raise ValueError("remote_tools.filesystem_roots must be a list of paths.")
        roots = tuple(dict.fromkeys(item.strip() for item in raw_roots))
    timeout = _number(value, "call_timeout_seconds", current.call_timeout_seconds, 0.1, 3600.0)
    approval = _number(
        value, "approval_timeout_seconds", current.approval_timeout_seconds, 0.1, 3600.0
    )
    size = int(_number(value, "max_result_bytes", current.max_result_bytes, 1024, MAX_REMOTE_RESULT_BYTES))
    concurrent = int(_number(value, "max_concurrent_calls", current.max_concurrent_calls, 1, 64))
    return RemoteToolsConfig(
        tools=tools,
        filesystem_roots=roots,
        call_timeout_seconds=timeout,
        max_result_bytes=size,
        max_concurrent_calls=concurrent,
        approval_timeout_seconds=approval,
    )


def _number(values: dict[object, object], key: str, default: float, low: float, high: float) -> float:
    if key not in values:
        return default
    raw = values[key]
    if isinstance(raw, bool) or not isinstance(raw, (int, float)) or not low <= raw <= high:
        raise ValueError(f"remote_tools.{key} must be a number from {low:g} to {high:g}.")
    return float(raw)


@dataclass(frozen=True, slots=True)
class HiveConfig:
    """Node-to-node (WebRTC hive) settings; active only while signed in."""

    enabled: bool = True
    # None reuses the account server URL.
    server_url: str | None = None
    # Overrides the STUN servers advertised by the server (e.g. self-hosted).
    stun_servers: tuple[str, ...] = ()
    node_name: str | None = None
    remote_tools: RemoteToolsConfig = RemoteToolsConfig()
    # Seconds to wait for a direct WebRTC link before falling back to the socket relay.
    direct_timeout_seconds: float = 8.0
    # Allow the encrypted relay over the signalling socket (also needs the server flag).
    relay_enabled: bool = True
    # Test/diagnostic only: skip WebRTC entirely and use the socket relay.
    force_relay: bool = False
    # Signed-in account devices are approved by a trusted node without a short code.
    auto_approve_account_devices: bool = True


@dataclass(frozen=True, slots=True)
class EngineConfig:
    # None selects the mode default (51516 production, 51515 development);
    # 0 requests an ephemeral port.
    port: int | None = None
    api: bool = True
    dev: bool = False
    gui: bool = False
    tui: bool = False
    headless: bool = False
    lan_enabled: bool = False
    node_id: str | None = None
    data_directory: Path | None = None
    conscious_graph: Path | None = None
    subconscious_graph: Path | None = None
    subconscious_model_id: str | None = None
    subconscious_enabled: bool = True
    reflection_interval_seconds: float = 86_400
    account_server_url: str | None = None
    # Optional model capability service; see capabilities.RemoteCapabilitySource.
    capabilities_url: str | None = None
    capabilities_token: str | None = None
    hive: HiveConfig = HiveConfig()
    # Set for secondary profile instances; `data_directory` is then used exactly as given.
    profile_id: str | None = None
    root_directory: Path | None = None

    @property
    def resolved_hive_server_url(self) -> str:
        return self.hive.server_url or self.resolved_account_server_url

    @property
    def resolved_account_server_url(self) -> str:
        return self.account_server_url or os.getenv(
            "SUBCONSCIOUS_SERVER_URL", "https://api.subconscious.chat"
        )

    @property
    def resolved_conscious_graph(self) -> Path:
        configured = self.conscious_graph or (
            Path(value)
            if (value := os.getenv("SUBCONSCIOUS_CONSCIOUS_GRAPH"))
            else None
        )
        return configured or self.resolved_data_directory / "graphs" / "conscious.json"

    @property
    def resolved_subconscious_graph(self) -> Path:
        configured = self.subconscious_graph or (
            Path(value)
            if (value := os.getenv("SUBCONSCIOUS_SUBCONSCIOUS_GRAPH"))
            else None
        )
        return (
            configured or self.resolved_data_directory / "graphs" / "subconscious.json"
        )

    @property
    def resolved_data_directory(self) -> Path:
        if self.profile_id is not None and self.data_directory is not None:
            return self.data_directory
        return self.resolved_root_directory

    @property
    def resolved_model_directory(self) -> Path:
        # Downloaded models are large and not account data: shared by all profiles.
        return self.resolved_root_directory / "models"

    @property
    def resolved_root_directory(self) -> Path:
        if self.root_directory is not None:
            return self.root_directory
        if self.data_directory is not None:
            base = self.data_directory
        elif sys.platform == "win32":
            app_data = os.getenv("APPDATA")
            base = (
                Path(app_data) if app_data else Path.home() / "AppData/Roaming"
            ) / "Subconscious"
        elif sys.platform == "darwin":
            base = Path.home() / "Library/Application Support/Subconscious"
        else:
            xdg_config_home = os.getenv("XDG_CONFIG_HOME")
            base = (
                Path(xdg_config_home) if xdg_config_home else Path.home() / ".config"
            ) / "subconscious"
        return Path(f"{base}-dev") if self.dev else base
