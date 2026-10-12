# unified_app

## Account authentication

The Flutter app sends sign-in, sign-up, session, and sign-out requests only to the authenticated local engine. The engine contacts the Subconscious identity server and stores the refresh token in the operating system keyring; cloud access and refresh tokens never enter Flutter.

The identity-server URL belongs to the engine, not a Flutter `--dart-define`. For local development, configure the engine before starting or restarting it:

```powershell
$env:SUBCONSCIOUS_SERVER_URL = 'http://127.0.0.1:5050/'
subconscious start --dev
```

Alternatively, set `engine.account_server_url: http://127.0.0.1:5050/` in the engine YAML configuration. The local engine joining token remains a separate credential used only between Flutter and the engine.
