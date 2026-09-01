# Subconscious Python Engine

Python port of `subconscious-net/src/Subconscious.Engine`, with the .NET engine as the protocol and behavior source of truth.

The engine provides loopback-first hosting, bearer authentication, atomic `runtime.json` discovery, async SQLite persistence, REST CRUD, encrypted model and configured-tool credentials, scope-checked workspace files, local RAG indexing/retrieval, Pydantic AI execution, approval-gated built-in tools, SSE fan-out, and the camel-case-envelope WebSocket chat protocol.

## Run

```powershell
conda run -n subconscious python -m pip install -e .
conda run -n subconscious subconscious-engine --dev
```

Production mode uses a generated token and an OS-assigned port. Development mode defaults to port `55681` and token `subconscious-dev-token`. Pass `--data-dir` to isolate local state. Desktop runs show a system tray icon with the active endpoint and a graceful **Quit** action; pass `--headless` on servers or CI machines without a desktop session. Use `--lan` to bind the API to all IPv4 interfaces.

## API additions

Besides workspace/thread/message CRUD, the authenticated `/api/v1` surface includes:

- `/model-configurations` and `/models` for redacted encrypted model configuration
- `/settings` for scoped app state
- `/workspaces/{uuid}/files...` for UTF-8 workspace file access
- `/tool-registry` and `/tools/catalog` for configured tools plus time, calculator, weather, todo, memory, notes, contacts, and knowledge built-ins
- `/workspaces/{uuid}/rag/index` and `/rag/search` for local retrieval
- `/stream` for SSE events and `/events` for WebSocket chat/approval traffic

Only `/api/v1/health` is public. HTTP endpoints require an `Authorization: Bearer ...` header; the `token` query parameter is accepted only during WebSocket connection setup for client compatibility. Model API keys and configured-tool headers are encrypted in `data.enc` and are never returned by API responses.
