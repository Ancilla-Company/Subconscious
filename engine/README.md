# Subconscious Python Engine

Python port of `subconscious-net/src/Subconscious.Engine`, with the .NET engine as the protocol and behavior source of truth.

The engine provides loopback-first hosting, bearer authentication, atomic `runtime.json` discovery, async SQLite persistence, REST CRUD, encrypted model and configured-tool credentials, scope-checked workspace files, local RAG indexing/retrieval, Pydantic AI execution, approval-gated built-in tools, unrestricted approval-gated filesystem tools, SSE fan-out, and the camel-case-envelope WebSocket chat protocol.

## Configuration

All engine and client commands accept `--config <path>`. The default is `config.yaml` in the engine data directory (or `SUBCONSCIOUS_CONFIG`). Precedence is command-line options, then supported environment variables, then YAML, then built-in defaults. Initialize and validate a configuration without exposing its token:

```powershell
subconscious config init --config .\subconscious.yaml
subconscious config set --config .\subconscious.yaml engine.port 51515
subconscious config validate --config .\subconscious.yaml
subconscious config show --config .\subconscious.yaml
subconscious start --config .\subconscious.yaml
```

The schema is versioned (`version: 1`) and rejects unknown keys. `engine` supports every `EngineConfig` setting, including graph paths, subconscious-worker timing, and `account_server_url`. `client` supports `engine_url`, `token`, `workspace`, and `flutter_device`; values may reference an environment variable using `${NAME}`. Unresolved placeholders remain inert until their environment variable is supplied. `config show` masks the token unless `--show-secrets` is explicitly supplied.

Account sessions are owned by the engine. It contacts the configured identity server (default `https://api.subconscious.chat`) and stores the refresh token in the current user's OS keyring. If the OS credential backend cannot write, the engine securely falls back to its existing Fernet-encrypted `data.enc` vault. Flutter receives account profile/session status only—never cloud access or refresh tokens. During local identity-server development, set `engine.account_server_url: http://127.0.0.1:5050/` or `SUBCONSCIOUS_SERVER_URL=http://127.0.0.1:5050/` before starting the engine.

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
wanted. Production is the default: port `51516` and a generated token.
Development mode (`--dev` or `SUBCONSCIOUS_ENV=development`) defaults to port
`51515`, token `subconscious-dev-token`, and a separate `-dev` data directory,
so both can run side by side. `--port 0` picks any free port. Use `--lan` for all-interface IPv4 binding.

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

## Client identification

The tray's Connected Clients menu shows readable labels such as `Desktop (local)`, `TUI (local)` or `Desktop (remote, 192.168.1.5)`. Clients identify themselves on the WebSocket (`/api/v1/events`) with query parameters, or with the matching `client.hello` data fields as a fallback (the only channel for hive peers):

| Query parameter | Hello field | Notes |
| --- | --- | --- |
| `client_type` | `clientType` | One of `desktop`, `mobile`, `tui`, `browser_extension`, `cli`, `web`. Anything else is shown as `Unknown`. |
| `client_name` | `clientName` | Free text, max 64 characters, control characters stripped. |
| `client_version` | `clientVersion` | Max 32 characters. |

Local vs remote is decided by the engine from the peer address (loopback or one of this machine's own addresses is local); `X-Forwarded-For` is ignored and hive/WebRTC peers are always remote. The existing `client=flutter` settings-scope parameter is unrelated and unchanged. The Chromium extension (`apps/chromium_extension`) connects with `client_type=browser_extension` while its popup or side panel is open.

## Selenium web smoke check

Install the pinned E2E extra with `python -m pip install -e ".[e2e]"`. Launch the connected Flutter web app, set its URL, and run the Selenium smoke harness; it waits for the web shell and saves a screenshot in pytest's temporary artifacts:

```powershell
$env:SUBCONSCIOUS_WEB_URL = 'http://localhost:<flutter-web-port>'
python -m pytest e2e -q
```

The suite deliberately skips when `SUBCONSCIOUS_WEB_URL` is not set, so unit-test runs never start browsers or require ChromeDriver.

## API additions

Besides workspace/thread/message CRUD, the authenticated `/api/v1` surface includes:

- `/model-configurations` and `/models` for redacted encrypted model configuration
- `/settings` for scoped app state
- `/account/session`, `/account/login`, `/account/signup/code`, `/account/signup/complete`, and `/account/logout` for engine-owned cloud account sessions
- `/workspaces/{uuid}/files...` for UTF-8 workspace file access
- `/tool-registry` and `/tools/catalog` for configured tools plus time, calculator, weather, todo, memory, notes, contacts, filesystem, and knowledge built-ins
- `/workspaces/{uuid}/rag/index` and `/rag/search` for local retrieval
- `/stream` for SSE events and `/events` for WebSocket chat/approval traffic

Workspace directories remain the scope for the workspace file API and RAG indexing. The `filesystem` model tools instead accept any user-specified path (absolute or process-relative), including paths outside workspace directories; they rely on the operating system's permissions and the configured tool-approval policy rather than a workspace-root block. `read_filesystem_file` and `write_filesystem_file` handle UTF-8 text directly and use structured extraction/generation for PDF, DOCX, XLSX, and PPTX files. Document generation preserves the supported normalized content, not arbitrary source formatting.

Only `/api/v1/health` (plus the OAuth callback and `POST /api/v1/pair`, see below) is public. HTTP endpoints require an `Authorization: Bearer ...` header; the `token` query parameter is accepted only during WebSocket connection setup for client compatibility. Model API keys and configured-tool headers are encrypted in `data.enc` and are never returned by API responses.

## Pairing a browser extension

Instead of pasting the joining token, the extension can pair through the cloud account:

1. The user signs in to the server from the extension; it reads `node_id` from the public `GET /api/v1/health` (the hive node id, or `null` before the hive identity exists).
2. The extension asks the server for `POST /nodes/{node_id}/pairing-assertion` with a random `client_nonce` and its `chrome-extension://` or `moz-extension://` origin.
3. The extension calls `POST /api/v1/pair` on the engine with `{assertion, client_nonce}`. The engine requires a matching extension `Origin` header (otherwise 403), then verifies the assertion at `POST {server}/nodes/{node_id}/pairing-assertion/verify` using its own account session, and checks that the returned `user_id` is the engine's signed-in user.
4. On success it returns `{token, client_id, expires_at}`. The `scp_...` token is used exactly like the joining token (HTTP bearer, WebSocket `?token=`).

Errors: 401 engine not signed in or assertion from another account, 403 bad/missing origin, 404 invalid/used/expired assertion, 429 more than 5 attempts a minute per origin and IP, 503 server unreachable.

Management (master engine token only; paired tokens get 401): `GET /api/v1/pair/clients` lists `{id, origin, label, created_at, last_used_at, expires_at}` (never hashes) and `DELETE /api/v1/pair/clients/{client_id}` revokes.

Security notes:
- The assertion is single use, lasts 60 seconds, and is bound to the engine node, the client nonce and the extension origin; replaying or changing any of them fails.
- Only SHA-256 hashes of client tokens are stored (`paired_clients.json` in the engine data directory, written atomically, `0600` on POSIX). Hashes are compared in constant time.
- Tokens expire after 30 days of inactivity (sliding; `last_used_at` is refreshed at most once a minute). At most 20 clients are kept; the oldest is evicted.
- A paired client has the same privileges as a joining token, except it cannot mint, list or revoke clients. Remote hive peers cannot reach `/api/v1/pair` (not in the role allowlist).

## Client-defined tools

A client (browser extension, VS Code extension, ...) can offer tools to the model over its `/api/v1/events` WebSocket. Frames use the usual `{"v":1,"type":...,"id":...,"data":...}` envelope.

Register (or replace) a group; the call replaces every tool of that group for this connection, so re-register whenever your tools change. An empty `tools` list removes the group. `tool.unregister` with `{"group": "..."}` also removes it.

```json
{"v":1,"type":"tool.register","id":"1","data":{
  "group":"browser", "title":"Browser",
  "tools":[{"id":"read_page","description":"Read the visible text of a tab.",
            "input_schema":{"type":"object","properties":{"tab_id":{"type":"integer"}}},
            "operation":"read","read_only":true,"timeout_seconds":30}]}}
```

- `group`: `^[a-z][a-z0-9_]{0,31}$`, not the slug of a built-in group. `title` is shown to the model and user.
- tool `id`: `^[A-Za-z][A-Za-z0-9_.\-]{0,63}$`; `description` up to 2000 chars; `input_schema` a JSON object with `"type":"object"`, up to 32 KiB. At most 64 tools per group and 8 groups per connection.
- `operation`: `read`, `create`, `update`, `delete` or `execute` (default `update`). `execute` is treated as `update` for approval. `read_only: true` forces `read`. `timeout_seconds` (optional, up to 300) overrides the 60 s default.
- Invalid payloads get an `error` frame (`tool.register rejected: <reason>`); nothing is registered. Hive peers cannot register schema-bearing tools (`error` frame); they keep the legacy UI tool ids only. A payload without `group`/`input_schema` is the legacy desktop UI registration and is unchanged.

The model sees each tool as `<group>__<id>` (non `[A-Za-z0-9_]` characters become `_`, max 64 chars, de-duplicated with a numeric suffix) with the description prefixed `[<title> via <client name>]`. When the model calls it, the engine sends, with the chat turn id as the envelope `id`:

```json
{"v":1,"type":"client.tool.request","id":"<turn id>","data":{"request_id":"...","tool_name":"read_page","group":"browser","arguments":{"tab_id":3}}}
```

The client answers on the same connection with `{"type":"client.tool.result","id":"<turn id>","data":{"request_id":"...","ok":true,"result":<json>}}` or `{"ok":false,"error":"..."}`. No answer in time (60 s or `timeout_seconds`) is reported to the model as a failure.

Permissions follow the built-in model. A tool needs approval iff the workspace/thread approval settings require it for its operation, and `tool.approval.request` reports the declared `operation` (including `execute`). Client tools are offered only when the turn has `tools_enabled`, and honour `tools_config`: `builtin_enabled: false`, `builtin[<group>].enabled` and `builtin[<group>].tools[<id>]` (default enabled). `GET /api/v1/tools/catalog` lists client groups under `builtin` (`{name, doc, operation}` per tool) while a client has them registered and, after it disconnects, until the engine restarts, so settings can still toggle them.

## Trust model: local, signed in, LAN

- **Local = full node.** A client is local only when the engine sees a loopback transport peer (127.0.0.0/8, ::1). Forwarded headers and client-sent flags are ignored, hive tunnel peers are always remote, and the bearer token in `runtime.json` (user-only file) is still required. `client.hello.ack` reports `local` for display.
- **Signed in = no code.** A trusted engine auto-approves pending devices of the signed-in account (`engine.hive.auto_approve_account_devices`, default `true`; max 5 per minute, logged at INFO). Only engine nodes can be trust roots. Set the flag to `false` to require the short-code approval again.
- **LAN, offline.** Without an account, clients join with the engine's LAN joining token; no hive is involved.
