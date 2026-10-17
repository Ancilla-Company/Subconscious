# Subconscious Python Engine

Python port of `subconscious-net/src/Subconscious.Engine`, with the .NET engine as the protocol and behavior source of truth.

The engine provides loopback-first hosting, bearer authentication, atomic `runtime.json` discovery, async SQLite persistence, REST CRUD, encrypted model and configured-tool credentials, scope-checked workspace files, local RAG indexing/retrieval, Pydantic AI execution, approval-gated built-in tools, unrestricted approval-gated filesystem tools, SSE fan-out, and the camel-case-envelope WebSocket chat protocol.

## Configuration

All engine and client commands accept `--config <path>`. The default is `config.yaml` in the engine data directory (or `SUBCONSCIOUS_CONFIG`). Precedence is command-line options, then supported environment variables, then YAML, then built-in defaults. Initialize and validate a configuration without exposing its token:

```powershell
subconscious config init --config .\subconscious.yaml
subconscious config set --config .\subconscious.yaml engine.port 50505
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
wanted. Production is the default: port `50506` and a generated token.
Development mode (`--dev` or `SUBCONSCIOUS_ENV=development`) defaults to port
`50505`, token `subconscious-dev-token`, and a separate `-dev` data directory,
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

Only `/api/v1/health` is public. HTTP endpoints require an `Authorization: Bearer ...` header; the `token` query parameter is accepted only during WebSocket connection setup for client compatibility. Model API keys and configured-tool headers are encrypted in `data.enc` and are never returned by API responses.

## Trust model: local, signed in, LAN

- **Local = full node.** A client is local only when the engine sees a loopback transport peer (127.0.0.0/8, ::1). Forwarded headers and client-sent flags are ignored, hive tunnel peers are always remote, and the bearer token in `runtime.json` (user-only file) is still required. `client.hello.ack` reports `local` for display.
- **Signed in = no code.** A trusted engine auto-approves pending devices of the signed-in account (`engine.hive.auto_approve_account_devices`, default `true`; max 5 per minute, logged at INFO). Only engine nodes can be trust roots. Set the flag to `false` to require the short-code approval again.
- **LAN, offline.** Without an account, clients join with the engine's LAN joining token; no hive is involved.
