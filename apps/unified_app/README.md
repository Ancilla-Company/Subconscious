# unified_app

## Account authentication

The Flutter app sends sign-in, sign-up, session, and sign-out requests only to the authenticated local engine. The engine contacts the Subconscious identity server and stores the refresh token in the operating system keyring; cloud access and refresh tokens never enter Flutter.

The identity-server URL belongs to the engine, not a Flutter `--dart-define`. For local development, configure the engine before starting or restarting it:

```powershell
$env:SUBCONSCIOUS_SERVER_URL = 'http://127.0.0.1:5050/'
subconscious start --dev
```

Alternatively, set `engine.account_server_url: http://127.0.0.1:5050/` in the engine YAML configuration. The local engine joining token remains a separate credential used only between Flutter and the engine.

## Starting the engine
On Windows, a production build starts `engine\subconscious-desktop.exe` (next to the `gui` folder of the installed package) when it finds no healthy engine, then waits up to 45 seconds for it to answer. If it cannot be found or never comes up, the dashboard shows the error instead of a blank connection failure, and the usual reconnect keeps trying.

Nothing is started when `SUBCONSCIOUS_ENGINE_DEV=true`, when an explicit engine endpoint is configured, on mobile or web, or on macOS and Linux. To test an unpackaged release build, point the app at an engine executable:

```powershell
flutter run -d windows --release --dart-define=SUBCONSCIOUS_ENGINE_EXE=C:\path\to\engine\subconscious-desktop.exe
```

Two app windows starting together are kept to one launch by an exclusive lock file (`gui-engine-launch.lock` in `%APPDATA%\Subconscious`). Follow-up: the Python engine has no real single-instance guard on Windows (`SO_REUSEADDR` lets a second process bind port 50506 and overwrite `runtime.json`), so starting it by hand while the app launches it can still produce two engines.

## Devices, executor picker and relay fallback

Signing in to the hive (Settings, Devices) registers this device as a thin node. It lists the other nodes of your account with their connection tier (`direct` or `ws-relay`) and lets you approve pending devices after comparing the six digit code.

**Where a message runs.** When another full node (an engine) is online, a "run on" control appears next to the send button. The default is the engine this app is connected to (the home engine). Picking another node sends the message as a task (`task.submit` with `executor`) through the home engine, which forwards it. The choice is stored per thread on this device only and is never synced. Without a choice the normal chat path is used unchanged. A status line above the composer shows queued, running, waiting for approval, done, failed, cancelled or interrupted with the node name, plus a Cancel button while the task is active, and assistant replies produced by a chosen node carry a small badge with its name. Task state comes from `task.status` frames, so thin clients need nothing but the home engine connection. The thread's latest task is also read from `GET /api/v1/hive/tasks` when the route is reachable.

**Tools exported by other devices.** When a peer asks to use a tool this device exports and the policy is `ask`, the approval card names the peer ("Work laptop wants to use a tool on this device"). Another UI answering first dismisses the prompt.

**Relay fallback.** Each connection tries a direct WebRTC link first (8 seconds by default). If it fails and the server reports `ws_relay_enabled`, the link is carried over the signalling socket as end to end encrypted frames (X25519, HKDF-SHA256, ChaCha20-Poly1305, peer identity checked against the pinned directory key; the server only sees ciphertext). The tier then shows `ws-relay`. In the background the app retries a direct link (no more often than every 60 seconds, backing off) and switches over without interrupting the chat or REST calls. See `webrtc.md` Appendix B for the protocol and `subconscious-dart/tests/vectors/relay_v1.json` for the cross-check vectors.

## Debugging account / HTTP

Debug builds print one line per request to the `flutter run` terminal, for example `[http] POST http://127.0.0.1:5050/auth/email/login?native=true -> 401 83ms`. Add `--dart-define=SUBCONSCIOUS_HTTP_LOG=verbose` for redacted request and response bodies (tokens, passwords and codes are never printed). The engine logs `account.request` lines (INFO) and rejections (WARNING) to `engine.log`; set the env var `SUBCONSCIOUS_HTTP_LOG=verbose` for the engine to log redacted request bodies. The engine also logs `account server: <host>` at startup. The app (dart-define) and the engine (env) must use the same `SUBCONSCIOUS_SERVER_URL`.
