"""Configured tool metadata and encrypted authentication persistence."""

from __future__ import annotations

import json
import re
from urllib.parse import urlparse
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.extra_schemas import ToolRegistryDto, UpsertToolRegistryRequest
from subconscious_engine.configuration import EncryptedModelConfigurationStore
from subconscious_engine.storage.models import ToolRegistryRecord, utc_now

_HEADER_NAME = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")
_TOOL_TYPES = frozenset({"script", "api", "mcp"})


class _Pairs(list[tuple[str, object]]):
    pass


class ToolRegistryService:
    def __init__(self, session: AsyncSession, credentials: EncryptedModelConfigurationStore) -> None:
        self.session = session
        self.credentials = credentials

    async def list(self) -> list[ToolRegistryDto]:
        rows = (await self.session.scalars(select(ToolRegistryRecord).order_by(
            ToolRegistryRecord.alias, ToolRegistryRecord.name))).all()
        configured = await self.credentials.get_tool_auth_config_ids()
        return [self._dto(row, row.uuid in configured) for row in rows]

    async def get(self, uuid: str) -> ToolRegistryDto | None:
        row = await self._row(uuid)
        if row is None:
            return None
        configured = await self.credentials.get_tool_auth_config_ids()
        return self._dto(row, uuid in configured)

    async def create(self, request: UpsertToolRegistryRequest) -> ToolRegistryDto:
        tool_type = self._tool_type(request.tool_type, "script")
        auth_type, auth_config = self._validate_auth(tool_type, request.auth_type, request.auth_config_json)
        identifier = str(uuid4())
        alias = self._alias(request.alias, request.name, None)
        now = utc_now()
        row = ToolRegistryRecord(uuid=identifier, name=self._normalize(request.name) or self._safe_name(alias, identifier),
            alias=alias, description=request.description, tool_type=tool_type,
            script_path=request.script_path, script_language=request.script_language,
            endpoint_url=self._endpoint(tool_type, request.endpoint_url), auth_type=auth_type,
            auth_env_var=None, status=self._required(request.status, "active", "Status"),
            created_at=now, updated_at=now)
        self.session.add(row)
        await self.session.commit()
        has_auth = await self.credentials.update_tool_auth_config(identifier, auth_config, request.clear_auth_config)
        return self._dto(row, has_auth)

    async def update(self, uuid: str, request: UpsertToolRegistryRequest) -> ToolRegistryDto | None:
        row = await self._row(uuid)
        if row is None:
            return None
        tool_type = self._tool_type(request.tool_type, row.tool_type)
        auth_type, auth_config = self._validate_auth(tool_type, request.auth_type, request.auth_config_json)
        row.name = self._normalize(request.name) or row.name
        row.alias = self._alias(request.alias, request.name, row.alias or row.name)
        row.description = request.description
        row.tool_type = tool_type
        row.script_path = request.script_path
        row.script_language = request.script_language
        row.endpoint_url = self._endpoint(tool_type, request.endpoint_url)
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
        return self._dto(row, has_auth)

    async def delete(self, uuid: str) -> bool:
        row = await self._row(uuid)
        if row is None:
            return False
        await self.session.delete(row)
        await self.session.commit()
        await self.credentials.remove_tool_auth_config(uuid)
        return True

    async def _row(self, uuid: str) -> ToolRegistryRecord | None:
        return await self.session.scalar(select(ToolRegistryRecord).where(ToolRegistryRecord.uuid == uuid))

    @staticmethod
    def _dto(row: ToolRegistryRecord, has_auth: bool) -> ToolRegistryDto:
        return ToolRegistryDto(id=row.id, uuid=row.uuid, name=row.name, alias=row.alias,
            description=row.description, tool_type=row.tool_type, script_path=row.script_path,
            script_language=row.script_language, endpoint_url=row.endpoint_url,
            auth_type=row.auth_type or ("api_key" if has_auth else None), has_auth_config=has_auth,
            status=row.status, created_at=row.created_at, updated_at=row.updated_at)

    @classmethod
    def _validate_auth(cls, tool_type: str, auth_type: str | None,
                       raw: str | None) -> tuple[str | None, str | None]:
        auth = cls._normalize(auth_type)
        if auth is not None:
            auth = auth.casefold()
            if auth != "api_key":
                raise ValueError("Only api_key authentication is supported for configured tools.")
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
            raise ValueError("Tool type must be script, api, or mcp.")
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
