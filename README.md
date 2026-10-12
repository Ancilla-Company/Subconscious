# Subconscious

<div align="center">
  <img alt="Subconscious banner" src="docs/white_banner.png" width="100%" />
</div>

<p align="center">
  <em>A local-first, agentic AI platform. A Python engine runs your agents; Flutter and Dart clients connect to it from desktop, mobile, web, and the terminal.</em>
</p>

> **Status: pre-release (0.1.0).** APIs, configuration, and UI are still changing.

<!-- TODO: add a screenshot of the Flutter app, e.g. docs/screenshots/thread.png -->

## Features

- **Local-first**: chats, logs, and settings are stored on your machine in SQLite.
- **Bring your own models**: connect your own provider keys or local servers. Keys are encrypted at rest and never returned by the API.
- **Agent graphs**: a foreground interactive graph plus a background "subconscious" graph, both declared as JSON and run with `pydantic-graph`.
- **Built-in tools**: filesystem, calculator, time, weather, todo, memory, notes, contacts, knowledge, and more. Tool use is approval-gated.
- **Workspaces and threads**: organize threads by workspace, with file tagging, attachments, and file preview.
- **Local RAG**: index and search workspace files locally.
- **Multiple clients**: adaptive Flutter app, terminal UI, Chromium extension, and CLI.

## Repository layout

| Path | Description |
| --- | --- |
| `engine/` | Python engine: REST, SSE, and WebSocket API, persistence, agent execution, tools, CLI. See [engine/README.md](engine/README.md). |
| `apps/core_business_logic/` | Pure Dart models, API contracts, and repositories. |
| `apps/shared_ui_kit/` | Flutter design tokens, themes, and shared widgets. |
| `apps/unified_app/` | Adaptive Flutter app (Android, iOS, Linux, macOS, Web, Windows). See [apps/unified_app/README.md](apps/unified_app/README.md). |
| `apps/tui_app/` | Pure Dart terminal client. |
| `apps/chromium_extension/` | Manifest V3 browser extension. See [apps/chromium_extension/README.md](apps/chromium_extension/README.md). |
| `docs/` | Design notes and style guide. |
| `tests/` | Engine tests. |

## Getting started

### Prerequisites

- Python 3.11 or newer
- Flutter 3.47.2 or newer (Dart 3.13.2 or newer)
- A supported Flutter toolchain for your target platform (Windows desktop builds need Microsoft's Windows compiler toolchain)

### 1. Start the engine

```shell
cd engine
python -m pip install -e .
subconscious start --dev
```

Development mode uses port `55681` and the token `subconscious-dev-token`. Production mode picks a free port and generates a token. Run `subconscious --help` for all commands.

### 2. Run a client

```shell
flutter pub get
flutter run -d <device> -t apps/unified_app/lib/main.dart
```

Or the terminal client:

```shell
dart run apps/tui_app/bin/main.dart
```

### Checks

```shell
flutter analyze
python -m pytest
```

## Configuration

See [engine/README.md](engine/README.md) for the YAML configuration, account sessions, and the API surface.

## Roadmap

- Multi-device "swarm" access
- Custom and external tools, MCP server connections
- Voice input
- Computer interaction tools
- More model providers

## Contributing

Issues and pull requests are welcome. This is a pre-release, so expect rapid change.

## License

MIT. See [LICENSE](LICENSE). Bundled third-party document preview libraries carry their own licenses under `apps/unified_app/assets/document_preview/licenses/`.
