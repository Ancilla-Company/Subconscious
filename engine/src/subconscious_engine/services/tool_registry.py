"""Configured tool metadata and encrypted authentication persistence."""

from __future__ import annotations

import json
import logging
import re
from typing import TYPE_CHECKING, Any
from urllib.parse import urlparse
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.extra_schemas import ToolRegistryDto, UpsertToolRegistryRequest
from subconscious_engine.configuration import EncryptedModelConfigurationStore
from subconscious_engine.storage.models import ToolRegistryRecord, utc_now

if TYPE_CHECKING:
    from subconscious_engine.services.configured_tools import ConfiguredToolRuntime

_LOG = logging.getLogger(__name__)
_HEADER_NAME = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")
_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_TOOL_TYPES = frozenset({"script", "api", "mcp", "cli", "acp"})
ACP_PERMISSIONS = frozenset({"read_only", "allow_all"})
DEFAULT_ACP_PERMISSIONS = "read_only"
MAX_ARGS = 64
MAX_ENV = 64
MAX_STRING = 4096


def parse_tool_config(raw: str | None) -> dict[str, Any]:
    """Decode ``config_json``; a damaged value yields an empty config (and is logged)."""
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        _LOG.warning("services.tool_registry.parse_tool_config: invalid config_json ignored", exc_info=True)
        return {}
    return value if isinstance(value, dict) else {}


class _Pairs(list[tuple[str, object]]):
    pass


class ToolRegistryService:
    def __init__(self, session: AsyncSession, credentials: EncryptedModelConfigurationStore,
                 runtime: ConfiguredToolRuntime | None = None) -> None:
        self.session = session
        self.credentials = credentials
        # Told when a row changes or goes away so a live MCP connection never outlives its config.
        self.runtime = runtime

    async def list(self) -> list[ToolRegistryDto]:
        rows = (await self.session.scalars(select(ToolRegistryRecord).order_by(
            ToolRegistryRecord.alias, ToolRegistryRecord.name))).all()
        configured = await self.credentials.get_tool_auth_config_ids()
        connected = await self._connected_ids(rows)
        return [self._dto(row, row.uuid in configured, row.uuid in connected) for row in rows]

    async def get(self, uuid: str) -> ToolRegistryDto | None:
        row = await self._row(uuid)
        if row is None:
            return None
        configured = await self.credentials.get_tool_auth_config_ids()
        connected = await self._connected_ids([row])
        return self._dto(row, uuid in configured, uuid in connected)

    async def _connected_ids(self, rows: Any) -> set[str]:
        """Tool uuids holding OAuth tokens; the encrypted store is only asked when an OAuth row exists."""
        if not any(row.auth_type == "oauth" for row in rows):
            return set()
        return await self.credentials.get_tool_oauth_connected_ids()

    async def create(self, request: UpsertToolRegistryRequest) -> ToolRegistryDto:
        tool_type = self._tool_type(request.tool_type, "script")
        auth_type, auth_config = self._validate_auth(tool_type, request.auth_type, request.auth_config_json)
        endpoint = self._endpoint(tool_type, request.endpoint_url)
        self._check_oauth(tool_type, auth_type, endpoint)
        config_json = self._config(tool_type, request, endpoint, auth_type)
        identifier = str(uuid4())
        alias = self._alias(request.alias, request.name, None)
        now = utc_now()
        row = ToolRegistryRecord(uuid=identifier, name=self._normalize(request.name) or self._safe_name(alias, identifier),
            alias=alias, description=request.description, tool_type=tool_type,
            script_path=request.script_path, script_language=request.script_language,
            endpoint_url=endpoint, auth_type=auth_type,
            auth_env_var=None, config_json=config_json,
            status=self._required(request.status, "active", "Status"),
            created_at=now, updated_at=now)
        self.session.add(row)
        await self.session.commit()
        has_auth = await self.credentials.update_tool_auth_config(identifier, auth_config, request.clear_auth_config)
        if auth_type == "oauth":
            await self._apply_oauth_secret(identifier, request)
        return self._dto(row, has_auth, False)

    async def update(self, uuid: str, request: UpsertToolRegistryRequest) -> ToolRegistryDto | None:
        row = await self._row(uuid)
        if row is None:
            return None
        tool_type = self._tool_type(request.tool_type, row.tool_type)
        auth_type, auth_config = self._validate_auth(tool_type, request.auth_type, request.auth_config_json)
        endpoint = self._endpoint(tool_type, request.endpoint_url)
        self._check_oauth(tool_type, auth_type, endpoint)
        config_json = self._config(tool_type, request, endpoint, auth_type)
        previous_auth, previous_endpoint = row.auth_type, row.endpoint_url
        previous_oauth = self._oauth_settings(row)
        row.name = self._normalize(request.name) or row.name
        row.alias = self._alias(request.alias, request.name, row.alias or row.name)
        row.description = request.description
        row.tool_type = tool_type
        row.script_path = request.script_path
        row.script_language = request.script_language
        row.endpoint_url = endpoint
        row.config_json = config_json
        row.auth_type = auth_type
        row.auth_env_var = None
        row.status = self._required(request.status, row.status, "Status")
        row.updated_at = utc_now()
        await self.session.commit()
        if auth_type != "api_key":
            await self.credentials.remove_tool_auth_config(uuid)
            has_auth = False
        else:
            has_auth = await self.credentials.update_tool_auth_config(uuid, auth_config, request.clear_auth_config)
        connected: bool | None = None
        if auth_type == "oauth":
            if previous_auth != "oauth" or previous_endpoint != endpoint:
                # A different server (or a new auth type): nothing stored applies any more.
                await self.credentials.clear_tool_oauth(uuid)
            elif previous_oauth != self._oauth_settings(row):
                # Another client id / scopes: the old registration and tokens are stale.
                await self.credentials.clear_tool_oauth(uuid, keep_client_secret=True)
            await self._apply_oauth_secret(uuid, request)
            connected = await self.credentials.has_tool_oauth_tokens(uuid)
        elif previous_auth == "oauth":
            await self.credentials.clear_tool_oauth(uuid)
        await self._invalidate(uuid)
        return self._dto(row, has_auth, connected)

    async def delete(self, uuid: str) -> bool:
        row = await self._row(uuid)
        if row is None:
            return False
        was_oauth = row.auth_type == "oauth"
        await self.session.delete(row)
        await self.session.commit()
        await self.credentials.remove_tool_auth_config(uuid)
        if was_oauth:
            await self.credentials.clear_tool_oauth(uuid)
        await self._invalidate(uuid)
        return True

    async def _invalidate(self, uuid: str) -> None:
        if self.runtime is not None:
            await self.runtime.invalidate(uuid)

    async def _row(self, uuid: str) -> ToolRegistryRecord | None:
        return await self.session.scalar(select(ToolRegistryRecord).where(ToolRegistryRecord.uuid == uuid))

    async def _apply_oauth_secret(self, uuid: str, request: UpsertToolRegistryRequest) -> None:
        secret = self._normalize(request.oauth_client_secret)
        if secret is not None:
            await self.credentials.patch_tool_oauth(uuid, {"client_secret": secret})
        elif request.clear_oauth_client_secret:
            await self.credentials.patch_tool_oauth(uuid, {"client_secret": None})

    @staticmethod
    def _oauth_settings(row: ToolRegistryRecord) -> tuple[str | None, str | None]:
        config = parse_tool_config(row.config_json)
        return config.get("oauthClientId"), config.get("oauthScopes")

    @staticmethod
    def _check_oauth(tool_type: str, auth_type: str | None, endpoint: str | None) -> None:
        if auth_type == "oauth" and (tool_type != "mcp" or endpoint is None):
            raise ValueError("OAuth sign-in applies to MCP tools with an endpoint URL only.")

    @staticmethod
    def _dto(row: ToolRegistryRecord, has_auth: bool, oauth_connected: bool | None = None) -> ToolRegistryDto:
        config = parse_tool_config(row.config_json)
        is_oauth = row.auth_type == "oauth"
        transport = None
        if row.tool_type == "mcp":
            transport = "http" if row.endpoint_url else ("stdio" if config.get("command") else None)
        return ToolRegistryDto(id=row.id, uuid=row.uuid, name=row.name, alias=row.alias,
            description=row.description, tool_type=row.tool_type, script_path=row.script_path,
            script_language=row.script_language, endpoint_url=row.endpoint_url,
            auth_type=row.auth_type or ("api_key" if has_auth else None), has_auth_config=has_auth,
            command=config.get("command"), args=config.get("args"), env=config.get("env"),
            cwd=config.get("cwd"), transport=transport,
            permissions=config.get("permissions") if row.tool_type == "acp" else None,
            oauth_client_id=config.get("oauthClientId") if is_oauth else None,
            oauth_scopes=config.get("oauthScopes") if is_oauth else None,
            oauth_connected=bool(oauth_connected) if is_oauth else None,
            status=row.status, created_at=row.created_at, updated_at=row.updated_at)

    @classmethod
    def _validate_auth(cls, tool_type: str, auth_type: str | None,
                       raw: str | None) -> tuple[str | None, str | None]:
        auth = cls._normalize(auth_type)
        if auth is not None:
            auth = auth.casefold()
            if auth not in {"api_key", "oauth"}:
                raise ValueError("Only api_key and oauth authentication are supported for configured tools.")
            if auth == "oauth" and tool_type != "mcp":
                raise ValueError("OAuth sign-in applies to MCP tools with an endpoint URL only.")
            if tool_type not in {"api", "mcp"}:
                raise ValueError("API key authentication is supported only for API and MCP endpoint tools.")
        raw = cls._normalize(raw)
        if raw is None:
            return auth, None
        if auth != "api_key":
            raise ValueError("API key headers require the api_key authentication type.")
        try:
            pairs = json.loads(raw, object_pairs_hook=_Pairs)
        except json.JSONDecodeError as error:
            raise ValueError("API key headers must be valid JSON.") from error
        if not isinstance(pairs, _Pairs) or not pairs:
            raise ValueError(cls._header_error())
        headers: dict[str, str] = {}
        names: set[str] = set()
        for name, value in pairs:
            folded = name.casefold()
            if folded in names or not _HEADER_NAME.fullmatch(name) or not isinstance(value, str) \
                    or not value.strip() or "\r" in value or "\n" in value:
                raise ValueError(cls._header_error())
            names.add(folded)
            headers[name] = value
        return auth, json.dumps(headers, separators=(",", ":"))

    @classmethod
    def _config(cls, tool_type: str, request: UpsertToolRegistryRequest, endpoint: str | None,
                auth_type: str | None) -> str | None:
        """Validate command/args/env/cwd for the tool type and serialize them for ``config_json``.

        ``env`` is stored in plain text and is NOT secret; credentials belong in the
        encrypted api_key headers (HTTP MCP tools).
        """
        oauth: dict[str, str] = {}
        client_id = cls._normalize(request.oauth_client_id)
        scopes = cls._normalize(request.oauth_scopes)
        secret = cls._normalize(request.oauth_client_secret)
        if auth_type == "oauth":
            if client_id is not None:
                oauth["oauthClientId"] = client_id
            if scopes is not None:
                oauth["oauthScopes"] = " ".join(scopes.split())
            if any(len(value) > MAX_STRING for value in oauth.values()):
                raise ValueError("OAuth client id or scopes are too long.")
            if secret is not None and client_id is None:
                raise ValueError("An OAuth client secret requires an OAuth client id.")
        elif client_id is not None or scopes is not None or secret is not None or request.clear_oauth_client_secret:
            raise ValueError("OAuth settings apply to tools with the oauth authentication type only.")
        command = cls._normalize(request.command)
        args, env, cwd = request.args, request.env, cls._normalize(request.cwd)
        has_any = command is not None or bool(args) or bool(env) or cwd is not None
        if tool_type == "mcp":
            if (endpoint is None) == (command is None):
                raise ValueError("An MCP tool needs exactly one of an endpoint URL or a command.")
            if endpoint is not None and has_any:
                raise ValueError("Command, arguments, environment and working directory apply to stdio MCP tools only.")
            if command is not None and auth_type is not None:
                raise ValueError("API key authentication applies to HTTP MCP tools only.")
        elif tool_type == "cli":
            if command is None:
                raise ValueError("A CLI tool requires a command.")
            if env:
                raise ValueError("Environment variables are not supported for CLI tools.")
        elif tool_type == "acp":
            if command is None:
                raise ValueError("An ACP agent requires a command.")
            if endpoint is not None or auth_type is not None:
                raise ValueError("ACP agents run as a local command; endpoints and authentication do not apply.")
        elif has_any:
            raise ValueError("Command settings are supported only for MCP, CLI and ACP tools.")
        permissions = cls._normalize(request.permissions)
        if permissions is not None and tool_type != "acp":
            raise ValueError("Permissions apply to ACP agents only.")
        if tool_type == "acp":
            permissions = (permissions or DEFAULT_ACP_PERMISSIONS).casefold()
            if permissions not in ACP_PERMISSIONS:
                raise ValueError("ACP permissions must be read_only or allow_all.")
        if not has_any:
            return json.dumps(oauth, separators=(",", ":")) if oauth else None
        if command is not None and len(command) > MAX_STRING:
            raise ValueError("Command is too long.")
        if cwd is not None and len(cwd) > MAX_STRING:
            raise ValueError("Working directory is too long.")
        args = list(args or [])
        if len(args) > MAX_ARGS or any(len(item) > MAX_STRING for item in args):
            raise ValueError(f"At most {MAX_ARGS} arguments of {MAX_STRING} characters are allowed.")
        env = dict(env or {})
        if len(env) > MAX_ENV:
            raise ValueError(f"At most {MAX_ENV} environment variables are allowed.")
        for key, value in env.items():
            if not _ENV_NAME.fullmatch(key):
                raise ValueError(f"Invalid environment variable name '{key}'.")
            if len(value) > MAX_STRING:
                raise ValueError(f"Environment variable '{key}' is too long.")
        stored: dict[str, Any] = {"command": command, "args": args or None, "env": env or None, "cwd": cwd}
        if permissions is not None:
            stored["permissions"] = permissions
        return json.dumps(stored, separators=(",", ":"))

    @classmethod
    def _endpoint(cls, tool_type: str, value: str | None) -> str | None:
        endpoint = cls._normalize(value)
        if endpoint is None:
            return None
        if tool_type not in {"api", "mcp"}:
            raise ValueError("Endpoint URLs are supported only for API and MCP tools.")
        parsed = urlparse(endpoint)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("Endpoint URL must be an HTTP or HTTPS URL without embedded credentials.")
        return endpoint

    @classmethod
    def _tool_type(cls, value: str | None, fallback: str) -> str:
        result = cls._required(value, fallback, "Tool type").casefold()
        if result not in _TOOL_TYPES:
            raise ValueError("Tool type must be script, api, mcp, cli, or acp.")
        return result

    @classmethod
    def _alias(cls, alias: str | None, name: str | None, fallback: str | None) -> str:
        result = cls._normalize(alias) or cls._normalize(name) or fallback
        if result is None:
            raise ValueError("A tool alias or name is required.")
        return result

    @classmethod
    def _required(cls, value: str | None, fallback: str, label: str) -> str:
        if value is not None and not value.strip():
            raise ValueError(f"{label} cannot be blank.")
        return cls._normalize(value) or fallback

    @staticmethod
    def _normalize(value: str | None) -> str | None:
        return value.strip() if isinstance(value, str) and value.strip() else None

    @staticmethod
    def _safe_name(alias: str, identifier: str) -> str:
        normalized = re.sub(r"[^a-z0-9]+", "-", alias.casefold()).strip("-")
        return f"tool-{normalized}" if normalized else f"tool-{identifier}"

    @staticmethod
    def _header_error() -> str:
        return ("API key headers must be a non-empty JSON object with valid, unique HTTP "
                "header names and non-empty string values.")
