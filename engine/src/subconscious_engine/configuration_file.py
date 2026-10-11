"""Strict, versioned YAML configuration for the Subconscious command line."""

from __future__ import annotations

import os
import re
from dataclasses import asdict, dataclass, fields
from pathlib import Path
from typing import Any

import yaml

from .config import EngineConfig

_VERSION = 1
_ENV_PATTERN = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")
_ENGINE_KEYS = frozenset(field.name for field in fields(EngineConfig))
_CLIENT_KEYS = frozenset({"engine_url", "token", "workspace", "flutter_device"})


class ConfigurationFileError(ValueError):
    """Raised when a YAML configuration file is invalid or unsafe to apply."""


@dataclass(frozen=True, slots=True)
class CommandConfiguration:
    engine: EngineConfig
    client: dict[str, str]


def default_config_path() -> Path:
    value = os.getenv("SUBCONSCIOUS_CONFIG")
    if value:
        return Path(value).expanduser()
    return EngineConfig().resolved_data_directory / "config.yaml"


def load_configuration(path: Path | None) -> CommandConfiguration:
    selected = path or default_config_path()
    if not selected.exists():
        return CommandConfiguration(EngineConfig(), {})
    try:
        raw = yaml.safe_load(selected.read_text(encoding="utf-8"))
    except OSError as error:
        raise ConfigurationFileError(f"Could not read configuration: {error}") from error
    except yaml.YAMLError as error:
        raise ConfigurationFileError(f"Invalid YAML configuration: {error}") from error
    if not isinstance(raw, dict):
        raise ConfigurationFileError("Configuration root must be a mapping.")
    _validate_keys(raw, {"version", "engine", "client", "node_id", "secrets"}, "root")
    if raw.get("version", _VERSION) != _VERSION:
        raise ConfigurationFileError(f"Unsupported configuration version: {raw.get('version')!r}.")
    engine_raw = _mapping(raw.get("engine", {}), "engine")
    if "node_id" in raw and "node_id" not in engine_raw:
        engine_raw["node_id"] = raw["node_id"]
    client_raw = _mapping(raw.get("client", {}), "client")
    _validate_keys(engine_raw, _ENGINE_KEYS, "engine")
    _validate_keys(client_raw, _CLIENT_KEYS, "client")
    resolved_engine = {key: _resolve_value(value) for key, value in engine_raw.items()}
    resolved_client = {key: _resolve_value(value) for key, value in client_raw.items()}
    _validate_engine_values(resolved_engine)
    _validate_client_values(resolved_client)
    return CommandConfiguration(_engine_from_mapping(resolved_engine), resolved_client)


def write_template(path: Path, *, overwrite: bool = False) -> None:
    if path.exists() and not overwrite:
        raise ConfigurationFileError(f"Configuration already exists: {path}")
    document = {
        "version": _VERSION,
        "engine": {
            "port": 0, "dev": False, "headless": False, "lan_enabled": False,
            "node_id": None, "data_directory": None, "conscious_graph": None,
            "subconscious_graph": None, "subconscious_model_id": None,
            "subconscious_enabled": True, "subconscious_interval_seconds": 86400,
            "subconscious_jitter_ratio": 0.1,
            "account_server_url": "https://api.subconscious.chat",
        },
        "client": {
            "engine_url": "http://localhost", "token": "${SUBCONSCIOUS_ENGINE_TOKEN}",
            "workspace": "General", "flutter_device": "windows",
        },
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(document, sort_keys=False), encoding="utf-8")


def show_configuration(path: Path | None, *, reveal_secrets: bool = False) -> str:
    selected = path or default_config_path()
    configuration = load_configuration(selected)
    engine = asdict(configuration.engine)
    engine = {key: str(value) if isinstance(value, Path) else value for key, value in engine.items()}
    client = dict(configuration.client)
    if not reveal_secrets and client.get("token"):
        client["token"] = "********"
    return yaml.safe_dump({"version": _VERSION, "engine": engine, "client": client}, sort_keys=False)


def set_configuration_value(path: Path, dotted_key: str, value: str) -> None:
    parts = dotted_key.split(".")
    if len(parts) != 2 or parts[0] not in {"engine", "client"}:
        raise ConfigurationFileError("Configuration key must be engine.<key> or client.<key>.")
    allowed = _ENGINE_KEYS if parts[0] == "engine" else _CLIENT_KEYS
    if parts[1] not in allowed:
        raise ConfigurationFileError(f"Unknown {parts[0]} setting: {parts[1]}.")
    raw: dict[str, Any] = {}
    if path.exists():
        try:
            loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError) as error:
            raise ConfigurationFileError(f"Could not read configuration: {error}") from error
        raw = loaded if isinstance(loaded, dict) else {}
    raw.setdefault("version", _VERSION)
    section = raw.setdefault(parts[0], {})
    if not isinstance(section, dict):
        raise ConfigurationFileError(f"{parts[0]} must be a mapping.")
    try:
        section[parts[1]] = yaml.safe_load(value)
    except yaml.YAMLError as error:
        raise ConfigurationFileError(f"Invalid setting value: {error}") from error
    candidate = path.with_suffix(path.suffix + ".tmp")
    candidate.parent.mkdir(parents=True, exist_ok=True)
    candidate.write_text(yaml.safe_dump(raw, sort_keys=False), encoding="utf-8")
    load_configuration(candidate)
    candidate.replace(path)


def environment_engine_overrides() -> dict[str, Any]:
    names = {
        "port": "SUBCONSCIOUS_PORT", "dev": "SUBCONSCIOUS_DEV",
        "headless": "SUBCONSCIOUS_HEADLESS", "lan_enabled": "SUBCONSCIOUS_LAN_ENABLED",
        "node_id": "SUBCONSCIOUS_NODE_ID", "data_directory": "SUBCONSCIOUS_DATA_DIR",
        "conscious_graph": "SUBCONSCIOUS_CONSCIOUS_GRAPH",
        "subconscious_graph": "SUBCONSCIOUS_SUBCONSCIOUS_GRAPH",
        "subconscious_model_id": "SUBCONSCIOUS_REFLECTION_MODEL",
        "subconscious_enabled": "SUBCONSCIOUS_SUBCONSCIOUS_ENABLED",
        "subconscious_interval_seconds": "SUBCONSCIOUS_SUBCONSCIOUS_INTERVAL_SECONDS",
        "subconscious_jitter_ratio": "SUBCONSCIOUS_SUBCONSCIOUS_JITTER_RATIO",
        "account_server_url": "SUBCONSCIOUS_SERVER_URL",
    }
    return {key: _coerce_environment(key, os.environ[name]) for key, name in names.items() if name in os.environ}


def environment_client_overrides() -> dict[str, str]:
    names = {"engine_url": "SUBCONSCIOUS_ENGINE_URL", "token": "SUBCONSCIOUS_ENGINE_TOKEN", "workspace": "SUBCONSCIOUS_WORKSPACE_UUID", "flutter_device": "SUBCONSCIOUS_FLUTTER_DEVICE"}
    return {key: os.environ[name] for key, name in names.items() if os.environ.get(name)}


def _mapping(value: Any, section: str) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ConfigurationFileError(f"{section} must be a mapping.")
    return value


def _validate_keys(value: dict[str, Any], allowed: set[str] | frozenset[str], section: str) -> None:
    unknown = sorted(set(value) - set(allowed))
    if unknown:
        raise ConfigurationFileError(f"Unknown {section} keys: {', '.join(unknown)}.")


def _resolve_value(value: Any) -> Any:
    if not isinstance(value, str):
        return value
    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        return os.environ.get(name, match.group(0))
    return _ENV_PATTERN.sub(replace, value)


def _engine_from_mapping(values: dict[str, Any]) -> EngineConfig:
    converted = dict(values)
    for key in ("data_directory", "conscious_graph", "subconscious_graph"):
        if converted.get(key) is not None:
            converted[key] = Path(str(converted[key])).expanduser()
    return EngineConfig(**converted)


def _validate_engine_values(values: dict[str, Any]) -> None:
    for key in ("dev", "api", "gui", "tui", "headless", "lan_enabled", "subconscious_enabled"):
        if key in values and not isinstance(values[key], bool):
            raise ConfigurationFileError(f"engine.{key} must be a boolean.")
    if "port" in values and (not isinstance(values["port"], int) or not 0 <= values["port"] <= 65535):
        raise ConfigurationFileError("engine.port must be an integer from 0 to 65535.")
    for key in ("subconscious_interval_seconds", "subconscious_jitter_ratio"):
        if key in values and (not isinstance(values[key], (int, float)) or values[key] < 0):
            raise ConfigurationFileError(f"engine.{key} must be a non-negative number.")
    if (url := values.get("account_server_url")) and (
        not isinstance(url, str) or not url.startswith(("http://", "https://"))
    ):
        raise ConfigurationFileError(
            "engine.account_server_url must start with http:// or https://."
        )


def _validate_client_values(values: dict[str, Any]) -> None:
    for key, value in values.items():
        if value is not None and not isinstance(value, str):
            raise ConfigurationFileError(f"client.{key} must be a string.")
    if (url := values.get("engine_url")) and not url.startswith(("http://", "https://")):
        raise ConfigurationFileError("client.engine_url must start with http:// or https://.")


def _coerce_environment(key: str, value: str) -> Any:
    if key in {"dev", "headless", "lan_enabled", "subconscious_enabled"}:
        if value.casefold() not in {"true", "false", "1", "0"}:
            raise ConfigurationFileError(f"Environment value for {key} must be true or false.")
        return value.casefold() in {"true", "1"}
    if key == "port":
        return int(value)
    if key in {"subconscious_interval_seconds", "subconscious_jitter_ratio"}:
        return float(value)
    return value
