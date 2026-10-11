"""Portable graph tool references and configurable external registry discovery."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import httpx
from pydantic import BaseModel, ConfigDict, Field
from pydantic_ai import Tool


OFFICIAL_MCP_REGISTRY = "https://registry.modelcontextprotocol.io"
REGISTRY_CONFIG_ENV = "SUBCONSCIOUS_TOOL_REGISTRY_CONFIG"


class RegistryEndpoint(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(pattern=r"^[A-Za-z][A-Za-z0-9_-]{0,63}$")
    base_url: str
    kind: str = "mcp"
    enabled: bool = True


class ToolRegistryConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    registries: list[RegistryEndpoint] = Field(default_factory=lambda: [
        RegistryEndpoint(id="official", base_url=OFFICIAL_MCP_REGISTRY)
    ])

    @classmethod
    def load(cls, data_directory: Path) -> tuple["ToolRegistryConfig", Path]:
        configured = os.getenv(REGISTRY_CONFIG_ENV)
        path = Path(configured).expanduser() if configured else data_directory / "tool-registries.json"
        if path.is_file():
            return cls.model_validate_json(path.read_text(encoding="utf-8")), path
        return cls(), path


class PortableToolRegistry:
    """Resolve stable graph references without serializing runtime callables."""

    def __init__(self, config: ToolRegistryConfig, timeout: float = 10.0) -> None:
        self.config = config
        self.timeout = timeout

    def endpoint(self, identifier: str) -> RegistryEndpoint:
        for endpoint in self.config.registries:
            if endpoint.id == identifier and endpoint.enabled:
                return endpoint
        raise KeyError(f"Tool registry '{identifier}' is not configured or enabled.")

    async def search(self, query: str, registry_id: str = "official", limit: int = 10) -> list[dict[str, Any]]:
        endpoint = self.endpoint(registry_id)
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.get(
                f"{endpoint.base_url.rstrip('/')}/v0.1/servers",
                params={"search": query, "limit": max(1, min(limit, 50))},
            )
            response.raise_for_status()
            payload = response.json()
        rows = payload.get("servers", payload) if isinstance(payload, dict) else payload
        if not isinstance(rows, list):
            return []
        return [self._normalize_server(registry_id, row) for row in rows[:limit] if isinstance(row, dict)]

    @staticmethod
    def _normalize_server(registry_id: str, row: dict[str, Any]) -> dict[str, Any]:
        server = row.get("server") if isinstance(row.get("server"), dict) else row
        name = str(server.get("name", server.get("id", "unknown")))
        version = str(server.get("version", "latest"))
        return {
            "identifier": f"mcp:{registry_id}:{name}@{version}",
            "name": name,
            "version": version,
            "description": server.get("description"),
            "registry": registry_id,
        }

    def search_tool(self, registry_id: str = "official") -> Tool[Any]:
        async def search_tool_registry(query: str, limit: int = 10) -> list[dict[str, Any]]:
            """Search a configured registry for portable MCP server identifiers."""
            return await self.search(query, registry_id, limit)

        return Tool(
            search_tool_registry,
            name="search_tool_registry",
            description=(
                "Search the configured tool registry. Results include stable identifiers; "
                "discovery does not install or execute a server."
            ),
        )

    def resolve_graph_tools(
        self, references: list[str], available: list[Tool[Any]], *, subconscious: list[Tool[Any]] | None = None
    ) -> list[Tool[Any]]:
        by_name = {tool.name: tool for tool in available}
        private = {tool.name: tool for tool in subconscious or []}
        resolved: list[Tool[Any]] = []
        for reference in references:
            if reference == "builtin:*":
                resolved.extend(tool for tool in available if tool not in resolved)
            elif reference.startswith("builtin:"):
                name = reference.partition(":")[2]
                if name not in by_name:
                    raise KeyError(f"Built-in tool '{name}' is unavailable.")
                resolved.append(by_name[name])
            elif reference.startswith("registry-search:"):
                resolved.append(self.search_tool(reference.partition(":")[2]))
            elif reference.startswith("subconscious:"):
                name = reference.partition(":")[2]
                if name not in private:
                    raise KeyError(f"Subconscious tool '{name}' is unavailable.")
                resolved.append(private[name])
            elif reference.startswith("mcp:"):
                raise RuntimeError(
                    f"'{reference}' identifies a registry server but is not installed locally."
                )
            else:
                raise ValueError(f"Unsupported portable tool reference '{reference}'.")
        return resolved
