# Subconscious Chromium extension

An unpacked Manifest V3 extension that uses the mobile app's layout: a top app bar (menu button, title, connection dot) and a left flyout drawer. It runs as the toolbar **popup** (400x560) and as a browser **side panel**; both load the same code and differ only in `<body data-mode="popup|panel">`. Plain ES modules, no build step.

## Layout

- **App bar**: hamburger, "Subconscious", connection status dot (popup also gets an "Open in side panel" button).
- **Drawer** (overlay with scrim; Esc, scrim click or selecting an item closes it; focus is trapped, `aria-modal`, the main area is `inert` while open; the slide respects `prefers-reduced-motion`): logo header, Workspaces / Threads / Files rows (`aria-current`, filled icon when selected), the context panel of the selected section (workspace list; workspace filter + thread list + New thread; folder select + lazy file tree), then a footer with Settings and the Account row.
- **Main area** fills the full height. Threads is the chat: thread header strip, scrolling messages, composer pinned to the bottom (Enter sends, Shift+Enter newline, disabled with a reason when not connected, Stop while a turn runs). Workspaces shows the selected workspace and a create form; Files is a read-only viewer; Settings and Account are pages.

## Modules

| File | Purpose |
| --- | --- |
| `app.js` | Thin entry: mounts the shell, syncs storage changes, starts up. |
| `icons.js` | Fluent icons copied from `design/assets/fluent` and the brand logo. |
| `ui/state.js` | Shared state, event bus, environment presets. |
| `ui/dom.js` | DOM helpers and kit-equivalent widgets (icon button, status dot, list row, banner, segmented control, fields). |
| `ui/shell.js`, `ui/drawer.js` | App bar, page routing, flyout drawer. |
| `ui/chat.js` | Chat view, code-block rendering, approval cards. |
| `ui/engine.js` | Engine REST (auto re-pair on 401), events WebSocket, chat/cancel/approval frames, tool-bridge hook. |
| `ui/server.js` | Server sign-in, token refresh, JSON fetch with `detail` errors. |
| `ui/pairing.js` | Engine probe and the pairing exchange. |
| `ui/connection.js` | Host permissions, connect/disconnect/sign-out, startup. |
| `ui/data.js` | Workspaces, threads, messages, files. |
| `ui/views/*.js` | Workspaces, Files, Settings, Account (and engine-side account forms). |
| `tools/**` | Browser tool bridge (separate component). |

Message text is only placed with `textContent`/text nodes; there are no inline event attributes.

## Environments and pairing

Settings holds environment presets: **Production** (engine `http://127.0.0.1:51516`, server `https://api.subconscious.chat`), **Development** (engine `http://127.0.0.1:51515`, server `http://127.0.0.1:5050`, dev token prefilled under Advanced) and **Custom**.

Account flow when not connected:
1. Sign in to the server (`POST /auth/email/login?native=true`; the rotated refresh token is stored and used via `POST /auth/refresh`). Creating an account happens in the desktop app or website.
2. The extension probes `GET {engine}/api/v1/health` ("Engine found" / "No engine found" with Retry) and reads `node_id`.
3. `POST {server}/nodes/{node_id}/pairing-assertion` with a random nonce and `location.origin`.
4. `POST {engine}/api/v1/pair`; the returned token, client id and expiry are saved in `chrome.storage.local` and the extension connects and opens Threads.

Host permissions for the engine and server origins are requested in the click gesture before other awaits. If the engine answers 401 to a paired token, the extension pairs again with the stored server session. Errors are mapped to plain messages (for example "Sign this engine in to the same account in the desktop app, then retry"). **Advanced** keeps the joining-token fallback; with a pasted token the engine's own account session decides between its sign-in forms and the signed-in card. **Disconnect** forgets the engine token; **Sign out** also clears the server session.

## Chat protocol

`chat.send`, streamed `chat.delta`, `chat.done`, `chat.error`, `chat.cancelled`; Stop sends `chat.cancel`. `tool.approval.request` renders an approval card (tool, operation, arguments, Approve/Deny) answered with `tool.approval.response` on the turn id. After `client.hello.ack` (and each reconnect) `ui/engine.js` dynamically imports `tools/bridge.js`, registers it, routes `client.tool.request` frames to `bridge.handleFrame` and disposes it when the socket closes. Unknown frames are ignored.

## Styling

`app.css` mirrors `apps/shared_ui_kit`: monochrome Default theme (light/dark via `prefers-color-scheme`), 3px field radius, compact density, `surfaceContainerLowest` fills, `outlineVariant` borders, plus the new AppListRow/AppTreeRow, AppIconButton, AppStatusDot, AppBanner, AppMessageBubble, AppSegmentedControl and flyout looks. Update it when the kit changes. Icons are Fluent only: add the SVG to `design/assets/fluent` and its `manifest.json` (pinned commit and sha256), then to `icons.js`.

## Load locally

1. Open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked** and select this folder.
2. Click the toolbar action, sign in on the Account page and pair. The side panel needs Chrome 116+.

## Testing

```powershell
Get-ChildItem -Recurse -Filter *.js | ForEach-Object { Get-Content $_.FullName -Raw | node --input-type=module --check }
python -m json.tool manifest.json
```

For visual checks, serve this folder with `python -m http.server`, load the pages with a temporary stub that defines `chrome.*`, `fetch` and `WebSocket`, and screenshot with `chrome --headless=new --screenshot`.
