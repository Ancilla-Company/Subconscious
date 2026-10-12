# UI and Engine CLI Completion Plan

## Goal
Deliver functionally equivalent Windows desktop, Flutter web, Android/mobile, browser-extension, and Dart TUI clients for the currently implemented engine API. Linux, macOS, and iOS are out of scope for active visual/E2E verification. The desktop Flutter client and `docs/ui-style-guide.md` are the visual baseline.

## Facts established at plan creation

- `apps/unified_app` is one adaptive Flutter client: wide desktop/web at 720 px and above, mobile below that threshold.
- Desktop/web/mobile already cover engine discovery, connection, workspace and thread CRUD, chat over WebSocket, file browsing/editing/previews, settings, model configurations, configured tools, and per-workspace tool/RAG policy.
- The engine exposes workspace, thread, message, file, settings, model, tool registry/catalog, RAG, SSE, and WebSocket endpoints. `/agui` is currently a server placeholder, not a feature to present.
- Browser-extension source does not exist yet. The extension will be a separate Chromium MV3 target using the mobile flyout UI model.
- `enginecli` currently means the `subconscious`/`subconscious-engine` console entry point in `engine/src/subconscious_engine/__main__.py`; it provides only service start, one-shot chat/notification, and reserved UI launch stubs.

## Delivery sequence

### 1. Establish the design system

1. Expand `apps/shared_ui_kit` with semantic color, spacing, radius, sizing, and desktop form tokens.
2. Consolidate repeated Windows-form and toolbar styling in shared component themes.
3. Add deterministic identifiers and accessibility labels to interactive application controls.
4. Add a lightweight component/gallery route or widget test harness for shared controls and key state variants.

**Acceptance:** desktop, web, mobile, and extension use the same tokens; no newly added feature hard-codes visual values already represented by tokens.

### 2. Finish engine API client coverage

1. Audit `RestEngineClient` and `EngineRepository` against all non-placeholder REST API routes.
2. Add missing workspace-wide RAG indexing/search and SSE client support only where they have an actionable UI purpose.
3. Remove or reconcile stale `app-state` client calls because the server uses scoped `/settings`.
4. Expose the same feature set across wide and narrow Flutter layouts, using progressively disclosed screens rather than hiding features.

**Acceptance:** each non-placeholder engine endpoint has an intentional client status: presented, used internally, or explicitly documented as protocol-only.

### 3. Browser extension (Chromium MV3)

1. Create an unpacked extension package with manifest, service worker, popup host, options host, content-script boundary, icons, and build scripts.
2. Use the compiled Flutter web UI for popup/options when viable; configure a narrow popup viewport and the existing mobile flyout.
3. Store endpoint/token only in extension storage; never inject credentials into page content scripts.
4. Provide popup connection/chat/workspace/thread/file entry points; options provide remote-engine configuration and full settings. Content scripts must remain opt-in and receive only minimum required data.
5. Add Selenium Chrome extension loading and popup/options E2E coverage.

**Acceptance:** the unpacked extension can connect to a configured engine, perform core flows, and visually follows the mobile flyout guide.

### 4. Engine CLI and YAML configuration

1. Define a versioned YAML schema covering server, security, runtime/data paths, graph paths, subconscious worker, default connection/client launch options, and environment-variable substitution.
2. Add `subconscious config init|validate|show|set` commands. Validation must reject unknown keys and invalid combinations before service launch.
3. Make `start`, `chat`, `tui`, `desktop`, `web`, and `extension` resolve options in this order: CLI flag > environment > YAML > built-in default.
4. Replace client-launch stubs with Windows commands that start the supported TUI/Flutter/extension development or packaged targets without printing tokens in normal output.
5. Add YAML fixtures and command-level tests.

**Acceptance:** a user can initialize, validate, inspect, and apply a YAML configuration; every exposed host option is configurable without code edits.

### 5. Automated verification

1. Add an `engine[e2e]` extra with pinned Selenium and pytest dependencies.
2. Add Selenium WebDriver fixtures using a local Chrome/ChromeDriver and explicit waits. Do not use Playwright.
3. Test the Flutter web client against a temporary, deterministic development engine and record screenshots for stable checkpoints.
4. Add Flutter widget/integration checks for desktop/mobile layout selection, navigation, forms, and API action states.
5. Add Windows desktop smoke automation for launch, connection, and native composition where supported locally.
6. Add a ConPTY/PTY-based TUI harness to feed commands and assert terminal cells/ANSI output at 80×24 and 120×30.

**Acceptance:** a single documented Windows command runs relevant unit, web E2E, screenshot, desktop smoke, Android/mobile, and TUI checks; failure artifacts include logs and screenshots.

## Feature matrix

| Engine feature | Desktop/wide web | Mobile | Extension popup/options | TUI |
|---|---|---|---|---|
| Connect and health | Existing; test | Existing; test | Popup/options | Command/status |
| Workspaces/threads/messages | Existing; test | Existing; test | Popup/expanded view | Commands/views |
| Streaming chat/approval | Existing; test | Existing; test | Popup | Interactive terminal |
| Files/read/write/preview | Existing; test | Existing; test | Read/focused file entry | Text operations |
| Settings | Existing; test | Existing; test | Options | YAML + commands |
| Models/tools | Existing; test | Existing; test | Options | YAML + commands |
| RAG | Existing partial; finish audit | Same focused flow | Options/focused action | Commands/status |
| SSE | Protocol only; add only if actionable | Same | Background notification only if required | Protocol only |
| AG-UI | Server placeholder; no UI | No UI | No UI | No UI |

## Non-goals and safeguards

- No Linux, macOS, or iOS automation in this delivery.
- No model credentials in screenshots, extension content scripts, logs, or normal CLI output.
- No silent external model calls in visual/E2E tests; fixtures must use deterministic test configuration.
- Browser-extension content-script features require a separate, explicit permission and threat-model review before implementation.

## Execution checkpoints

1. **Foundation:** guide, plan, token baseline, automation dependency declaration.
2. **CLI:** YAML loader/schema, commands, tests, documentation.
3. **Shared client:** missing transport/controller/UI feature coverage and responsive validation.
4. **Extension:** MV3 scaffold, Flutter packaging/integration, Selenium flows.
5. **Verification:** screenshots and E2E artifacts on Windows/Chrome/Android/TUI.

Completion means all executable targets launch with documented commands, supported features behave consistently with the engine API, and the Windows verification matrix passes.
