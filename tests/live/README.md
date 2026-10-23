# Live (end-to-end) tests

Tests that run the REAL subconscious-server, REAL engine process(es) and REAL clients together. The contract
is `.agents/tasks/live-tests/contracts.md`. The stack launcher is `scripts/live_stack.py`; it writes
`build/live-stack/stack.json` (or `$SC_LIVE_STACK_DIR/stack.json`).

## What this tier is for

The unit tests test each side against a fake of the other. This tier runs them together, so it catches the bugs
that live in the gaps: clients that collide (`Client_ID already in use`), wrong `platform`/name registration
(`browser` vs `web`), presence (online/offline), "this device", the relay fallback, pairing and client tools.
It is separate from, and never part of, the quick unit run.

Prerequisite: the server venv at `../subconscious-server/.venv` (the tests are skipped with a reason without it).
Everything else is created in a temporary directory with random ports and secrets; nothing is committed.

## Python live tests (this folder)

`test_live_identity.py`, `test_live_collisions.py`, `test_live_presence.py`, `test_live_same_device.py`,
`test_live_relay.py`, `test_live_client_tools.py`, `test_live_pairing.py` and `test_hive_live.py` (the original
server + engines interop). Each test has a docstring naming the bug class it guards.

Gating (`conftest.py`): live tests are always COLLECTED, so they appear in the Testing panel, but are SKIPPED with
`live test: run it from the Testing panel, "Test: Live ..." task, or set SC_LIVE=1` unless the run asks for them:
`SC_LIVE=1`, a path or node id under `tests/live` (what the panel passes when you run the folder or one test), or
`-m live`. So `pytest tests` stays the fast unit run.

```powershell
python -m pytest tests/live -p no:cacheprovider        # everything here, about 2.5 minutes
python -m pytest tests/live/test_live_collisions.py -p no:cacheprovider
python -m pytest tests -p no:cacheprovider             # unit run: live tests show as skipped
```

By default the tests start their own server and engines (hermetic). To run them against a stack you started
yourself, set `SC_LIVE_STACK=<path to stack.json>`.

### The stack launcher

`scripts/live_stack.py` starts the real server and N real engine processes, signs each engine in to its account and
writes `stack.json` (schema in the contract). Starting it twice is harmless: a running stack is reused.

```powershell
python scripts/live_stack.py --no-webrtc     # task "Live: Start stack"; ready when LIVE-STACK-READY is printed
python scripts/live_stack.py --stop          # task "Live: Stop stack"
```

Options: `--engines N`, `--no-webrtc` (force the signalling relay), `--keep` (keep the data dirs). The Dart and
TypeScript live tests need a running stack (they never start one); `SC_LIVE_STACK_DIR` moves its output.

### Adding a scenario

Add a `test_*.py` here, use the `server`, `account`, `engine` or `engine_factory` fixtures, wait with `until(...)`
(never bare sleeps), and write the bug class in the docstring.

### Known findings (see the contract for the matrix)

* A brand-new thin node's first relay connect to the engine can take 10 s (the engine learns of the node on its
  next presence refresh); the tests retry.
* The VS Code extension still registers tools with the older `tool.call` contract; the engine lists only the
  `group`/`client.tool.request` contract (see `subconscious-code` live tests).

## Dart live tests

Where: `apps/core_business_logic/test/live/` (hive client, relay, presence, account isolation) and
`apps/unified_app/test/live/` (HiveRuntime, extension identity, extension pairing). Shared attach/gating helper:
`apps/core_business_logic/test/live/live_stack.dart` (unified_app imports it by relative path).

They never start the stack, they attach to one. WebRTC does not exist in the Dart test VM, so the clients use a
transport factory that always fails and reach the engine through the signalling RELAY (real relay crypto and
handshake in Dart). Start the stack with `--no-webrtc` (the "Live: Start stack" task does what the launcher does by
default; the engine is configured to force the relay).

Gating: the tests are always collected (they show in the Testing panel) and carry the `live` tag. Without a
reachable stack every one is SKIPPED with
`live test: start the stack with the task "Live: Start stack" (or set SC_LIVE_STACK=<path to stack.json>)`.
The stack file is `SC_LIVE_STACK`, else `<repo>/build/live-stack/stack.json`, and the server and engine must answer
`/health` (a stale file counts as "no stack").

Start the stack (once, leave it running):

```powershell
python scripts/live_stack.py --no-webrtc          # task: "Live: Start stack"
# ... later
python scripts/live_stack.py --stop               # task: "Live: Stop stack"
```

From the Testing panel: start the stack, then run the `test/live` folder (or one test) under `apps/core_business_logic`
or `apps/unified_app`. The Dart extension runs Dart-Code's test discovery as usual; the live files are in the tree
and turn from "skipped" to "run" as soon as the stack file exists (set `SC_LIVE_STACK` in the environment of the IDE
if you keep the stack file elsewhere).

From the CLI:

```powershell
$env:SC_LIVE_STACK = "$PWD\build\live-stack\stack.json"
cd apps\core_business_logic; flutter test --tags live
cd ..\unified_app;           flutter test --tags live
# the quick unit run, without the live tests
flutter test --exclude-tags live
```

Or run the task "Test: Live (Dart)" (starts the stack, then both packages). If a stack is already running, run
"Test: Live (Dart core)" and "Test: Live (Dart app)" instead.

To keep a Dart run away from other agents' stacks, give it its own directory:
`$env:SC_LIVE_STACK_DIR = "build/live-stack/dart"` for the launcher and
`$env:SC_LIVE_STACK = "$PWD\build\live-stack\dart\stack.json"` for the tests.

Notes:

* The tests sign in with the account password: the refresh token in `stack.json` is single use and is never spent.
* Pairing: the Dart VM sends no `Origin` header, so the test client adds the extension origin the way a browser does.
  `ExtensionPairing.findEngine()` probes the fixed ports 51515/51516, so the pairing test calls `probe(<engine url>)`.
* Web registration (`platform web`, `Subconscious (web)`): `kIsWeb` cannot be faked in the VM, so the test passes
  those values through the same `HiveClient` arguments the runtime uses. Run it with
  `flutter test test/live --tags live --dart-define=SUBCONSCIOUS_CLIENT=web` to also check `AppClient`.
