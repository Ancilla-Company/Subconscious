# Subconscious Python Engine

Python port of `subconscious-net/src/Subconscious.Engine`, with the .NET engine as the protocol and behavior source of truth.

The engine provides loopback-first hosting, bearer authentication, atomic `runtime.json` discovery, async SQLite persistence, REST CRUD, encrypted model and configured-tool credentials, scope-checked workspace files, local RAG indexing/retrieval, Pydantic AI execution, approval-gated built-in tools, SSE fan-out, and the camel-case-envelope WebSocket chat protocol.

## CLI

Install the package in editable mode during development; this adds both the
`subconscious` command and the compatibility alias `subconscious-engine`:

```powershell
conda run -n subconscious python -m pip install -e .
subconscious
subconscious start --dev
```

Running `subconscious` without a command prints help. `subconscious start`
runs the engine with its tray status indicator. Add `--detached` to launch it as
a background process, and independently add `--no-tray` when no tray icon is
wanted. Development mode defaults to port `55681` and token
`subconscious-dev-token`; production chooses an available port and generated
token. Use `--lan` for all-interface IPv4 binding.

The tray menu can copy a future-compatible join command containing the engine
URL and joining token. It also exposes desktop, browser, and web UI launch
stubs; activating the tray icon invokes the desktop stub. Treat copied join
commands as credentials because they contain the bearer token.

A single response can be invoked as an agent harness against the running
engine:

```powershell
subconscious chat "Summarize this workspace" --workspace General
subconscious chat "Continue" --thread <thread-uuid> --tools
```

Without `--workspace` or `--thread`, chat uses (or creates) the `General`
workspace and starts a new thread. Responses go to stdout; a newly created
thread ID is written to stderr. The `tui`, `desktop`, `web`, and `extension`
client launch commands are currently reserved stubs.

## API additions

Besides workspace/thread/message CRUD, the authenticated `/api/v1` surface includes:

- `/model-configurations` and `/models` for redacted encrypted model configuration
- `/settings` for scoped app state
- `/workspaces/{uuid}/files...` for UTF-8 workspace file access
- `/tool-registry` and `/tools/catalog` for configured tools plus time, calculator, weather, todo, memory, notes, contacts, and knowledge built-ins
- `/workspaces/{uuid}/rag/index` and `/rag/search` for local retrieval
- `/stream` for SSE events and `/events` for WebSocket chat/approval traffic

Only `/api/v1/health` is public. HTTP endpoints require an `Authorization: Bearer ...` header; the `token` query parameter is accepted only during WebSocket connection setup for client compatibility. Model API keys and configured-tool headers are encrypted in `data.enc` and are never returned by API responses.
