"""Tiny stdio MCP server used by the configured-tool tests."""

import os

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

server = FastMCP("echo")
COUNTER = {"calls": 0}


@server.tool(annotations=ToolAnnotations(readOnlyHint=True))
def echo(text: str) -> str:
    """Return the text unchanged."""
    COUNTER["calls"] += 1
    return text


@server.tool()
def shout(text: str) -> str:
    """Return the text upper-cased."""
    COUNTER["calls"] += 1
    return text.upper()


@server.tool()
def server_info() -> str:
    """Return the server process id, call count and the TEST_MARKER variable."""
    COUNTER["calls"] += 1
    return f"{os.getpid()}:{COUNTER['calls']}:{os.environ.get('TEST_MARKER', '')}"


@server.tool()
def explode() -> str:
    """Always fail."""
    raise ValueError("boom")


if __name__ == "__main__":
    server.run("stdio")
