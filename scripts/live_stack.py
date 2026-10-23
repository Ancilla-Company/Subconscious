"""Boot a throw-away live stack: the REAL server plus N REAL engine processes.

    python scripts/live_stack.py [--engines N] [--no-webrtc] [--keep]
    python scripts/live_stack.py --stop

The stack runs until Ctrl+C, ``--stop`` (a stop file next to ``stack.json``) or the launcher process
is killed. ``build/live-stack/stack.json`` describes it (see ``tests/live/README.md``) and the last
line printed once it is usable is ``LIVE-STACK-READY <path to stack.json>``.

Everything is temporary and random: ephemeral loopback ports, secrets, data directories (removed on
stop unless ``--keep``). Python live tests attach to a running stack with
``SC_LIVE_STACK=<path to stack.json>``; the Dart and TypeScript live tests do the same.
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import shutil
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tests" / "live"))

import live_server  # noqa: E402
from live_engines import EngineProcess, start_engine  # noqa: E402

# ``SC_LIVE_STACK_DIR`` lets several stacks run side by side (each Dart/TypeScript suite its own).
STACK_DIR = Path(os.environ.get("SC_LIVE_STACK_DIR") or REPO / "build" / "live-stack")
STACK_JSON = STACK_DIR / "stack.json"
STOP_FILE = STACK_DIR / "stop"
ACCOUNT_NAMES = {"A": "alice", "B": "bob"}


def build_stack_json(server: live_server.RunningServer, engines: list[EngineProcess]) -> dict:
    accounts = {}
    for label, name in ACCOUNT_NAMES.items():
        account = server.accounts[label]
        accounts[name] = {
            "email": account["email"], "password": account["password"], "userId": account["user_id"],
            "accessToken": account["access_token"], "refreshToken": account["refresh_tokens"][0],
        }
    return {
        "version": 1,
        "startedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pid": os.getpid(),
        "server": {"url": server.url, "wsUrl": "ws://" + server.url.split("://", 1)[1]},
        "accounts": accounts,
        "engines": [engine.descriptor() for engine in engines],
    }


def write_atomic(path: Path, document: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(document, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def request_stop() -> int:
    """``--stop``: ask a running launcher to shut down; wait for stack.json to disappear."""
    if not STACK_JSON.exists():
        print("no live stack is running (no stack.json)")
        return 0
    STOP_FILE.parent.mkdir(parents=True, exist_ok=True)
    STOP_FILE.write_text("stop", encoding="utf-8")
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if not STACK_JSON.exists():
            print("live stack stopped")
            return 0
        time.sleep(0.3)
    try:
        pid = json.loads(STACK_JSON.read_text(encoding="utf-8"))["pid"]
    except (OSError, ValueError, KeyError):
        pid = None
    print(f"the launcher (pid {pid}) did not stop in 60 s; killing it", file=sys.stderr)
    if pid:
        import subprocess

        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True, check=False)  # noqa: S603, S607
    STACK_JSON.unlink(missing_ok=True)
    STOP_FILE.unlink(missing_ok=True)
    return 0


def _stack_is_alive() -> bool:
    """True when ``stack.json`` describes a launcher whose server and engines still answer."""
    import urllib.request

    try:
        stack = json.loads(STACK_JSON.read_text(encoding="utf-8"))
        urls = [stack["server"]["url"].rstrip("/") + "/health"] + [
            engine["url"].rstrip("/") + "/api/v1/health" for engine in stack["engines"]
        ]
    except (OSError, ValueError, KeyError):
        return False
    for url in urls:
        try:
            with urllib.request.urlopen(url, timeout=2) as response:  # noqa: S310 (loopback only)
                if response.status != 200:
                    return False
        except OSError:
            return False
    return True


def run(args: argparse.Namespace) -> int:
    if STACK_JSON.exists():
        # Starting twice is harmless: a stack that is really up is reused (so "Test: Live" tasks that
        # depend on "Live: Start stack" work whether or not you started it yourself); a leftover
        # stack.json of a dead launcher is cleaned up and a fresh stack is started.
        if _stack_is_alive():
            print(f"live stack already running ({STACK_JSON})", flush=True)
            print(f"LIVE-STACK-READY {STACK_JSON}", flush=True)
            return 0
        print(f"removing the stale {STACK_JSON}", flush=True)
        STACK_JSON.unlink(missing_ok=True)
        STOP_FILE.unlink(missing_ok=True)
    if not live_server.server_available():
        print(f"the server venv is not available at {live_server.SERVER_PYTHON}", file=sys.stderr)
        return 2
    STOP_FILE.unlink(missing_ok=True)
    root = Path(tempfile.mkdtemp(prefix="sc-live-stack-"))
    server = live_server.RunningServer(
        root / "server", access_token_minutes=720, settings=live_server.LIVE_SETTINGS
    )
    engines: list[EngineProcess] = []

    def shutdown() -> None:
        for engine in reversed(engines):
            engine.stop()
        engines.clear()
        server.stop()
        STACK_JSON.unlink(missing_ok=True)
        STOP_FILE.unlink(missing_ok=True)
        if not args.keep:
            shutil.rmtree(root, ignore_errors=True)
        else:
            print(f"kept {root}")

    atexit.register(shutdown)
    try:
        print("starting the server ...", flush=True)
        server.start()
        print(f"server up at {server.url}", flush=True)
        for index in range(args.engines):
            label = "A" if index % 2 == 0 else "B"
            name = f"engine-{chr(ord('a') + index)}"
            print(f"starting {name} (account {ACCOUNT_NAMES[label]}) ...", flush=True)
            engines.append(
                start_engine(
                    root / name, name, server.url, server.accounts[label], ACCOUNT_NAMES[label],
                    relay=args.no_webrtc,
                )
            )
        write_atomic(STACK_JSON, build_stack_json(server, engines))
        print(f"LIVE-STACK-READY {STACK_JSON}", flush=True)
        while not STOP_FILE.exists():
            time.sleep(0.5)
            if server.process is not None and server.process.poll() is not None:
                print("the server exited unexpectedly:\n" + server.log_tail(), file=sys.stderr)
                return 1
            for engine in engines:
                if not engine.alive():
                    print(f"{engine.name} exited unexpectedly:\n{engine.log_tail()}", file=sys.stderr)
                    return 1
        print("stop requested", flush=True)
        return 0
    except KeyboardInterrupt:
        print("interrupted", flush=True)
        return 0
    except Exception as error:  # report and clean up; the traceback is in the message chain
        print(f"live stack failed: {error}", file=sys.stderr)
        return 1
    finally:
        shutdown()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engines", type=int, default=1, help="number of real engine processes (default 1)")
    parser.add_argument(
        "--no-webrtc", action="store_true",
        help="force the signalling relay (engine.hive.force_relay) instead of WebRTC",
    )
    parser.add_argument("--keep", action="store_true", help="keep the temporary data directories")
    parser.add_argument("--stop", action="store_true", help="stop a running stack and exit")
    args = parser.parse_args()
    if args.stop:
        return request_stop()
    if args.engines < 0:
        parser.error("--engines must not be negative")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
