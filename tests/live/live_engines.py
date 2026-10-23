"""REAL engine processes for the live tier (used by ``scripts/live_stack.py`` and the live conftest).

Each engine is ``python -m subconscious_engine start --dev --port 0 --no-tray`` with its own data
directory, a config file that points at the live server (and optionally forces the socket relay),
and an isolated credential store (``live_keyring``) so nothing touches the developer's keyring,
DPAPI key or real engine data. The engine is signed in through its own
``POST /api/v1/account/login`` and has enrolled itself as a node once it shows up in the server's
``GET /nodes`` as online.
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
import yaml

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
ENGINE_SRC = REPO / "engine" / "src"
_KEEP_ENV = (
    "SYSTEMROOT", "SYSTEMDRIVE", "WINDIR", "PATH", "PATHEXT", "COMSPEC", "TEMP", "TMP",
    "USERPROFILE", "LOCALAPPDATA", "HOMEDRIVE", "HOMEPATH", "PROCESSOR_ARCHITECTURE", "CONDA_PREFIX",
)
LOOPBACK = "127.0.0.1"


def _kill_tree(process: subprocess.Popen[Any]) -> None:
    if process.poll() is not None:
        return
    if sys.platform == "win32":
        subprocess.run(  # noqa: S603, S607 - fixed command
            ["taskkill", "/T", "/F", "/PID", str(process.pid)], capture_output=True, check=False, timeout=30
        )
    else:
        process.kill()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()


@dataclass
class EngineProcess:
    name: str
    account: str
    root: Path
    process: subprocess.Popen[Any] | None = None
    url: str = ""
    token: str = ""
    node_id: str = ""
    pid: int = 0
    log_path: Path = field(default_factory=Path)

    @property
    def data_dir(self) -> Path:
        """The engine's real data directory (``--dev`` appends ``-dev`` to the one passed)."""
        return Path(str(self.root / "data") + "-dev")

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"}

    def ws_url(self, **query: str) -> str:
        from urllib.parse import urlencode

        params = urlencode({"token": self.token, **query})
        return f"ws://{self.url.split('://', 1)[1]}/api/v1/events?{params}"

    def get(self, path: str, **kwargs: Any) -> httpx.Response:
        return httpx.get(self.url + path, headers=self.headers, timeout=15, **kwargs)

    def log_tail(self, size: int = 3000) -> str:
        try:
            return self.log_path.read_text(encoding="utf-8", errors="replace")[-size:]
        except OSError:
            return ""

    def alive(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def stop(self) -> None:
        process, self.process = self.process, None
        if process is not None:
            _kill_tree(process)

    def descriptor(self) -> dict[str, Any]:
        return {
            "name": self.name, "account": self.account, "url": self.url, "token": self.token,
            "nodeId": self.node_id, "dataDir": str(self.data_dir), "pid": self.pid,
        }


def engine_environment(root: Path, server_url: str) -> dict[str, str]:
    env = {key: os.environ[key] for key in _KEEP_ENV if key in os.environ}
    env.update(
        {
            "PYTHONPATH": os.pathsep.join([str(ENGINE_SRC), str(HERE)]),
            "PYTHONIOENCODING": "utf-8",
            "PYTHONUNBUFFERED": "1",
            "APPDATA": str(root / "appdata"),
            "SUBCONSCIOUS_SERVER_URL": server_url,
            "SUBCONSCIOUS_FERNET_KEY": base64.urlsafe_b64encode(secrets.token_bytes(32)).decode(),
            "PYTHON_KEYRING_BACKEND": "live_keyring.FileKeyring",
            "SC_LIVE_KEYRING_FILE": str(root / "keyring.json"),
        }
    )
    return env


def _wait(predicate: Any, timeout: float, what: str, process: subprocess.Popen[Any] | None = None) -> Any:
    deadline = time.monotonic() + timeout
    last: Exception | None = None
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise RuntimeError(f"the process exited ({process.returncode}) while waiting for {what}")
        try:
            result = predicate()
            if result:
                return result
        except (OSError, ValueError, httpx.HTTPError, KeyError) as error:
            last = error
        time.sleep(0.2)
    raise RuntimeError(f"timed out waiting for {what}" + (f" (last error: {last!r})" if last else ""))


def start_engine(
    root: Path,
    name: str,
    server_url: str,
    account: dict[str, Any],
    account_label: str,
    *,
    relay: bool = True,
    sign_in: bool = True,
    timeout: float = 90.0,
) -> EngineProcess:
    """Start one real engine; signed in to ``account`` and online in the server directory.

    ``relay=True`` forces the socket relay (no WebRTC), the documented ``engine.hive.force_relay``
    switch, so thin clients reach the engine through the signalling relay.
    """
    root.mkdir(parents=True, exist_ok=True)
    engine = EngineProcess(name=name, account=account_label, root=root, log_path=root / "engine.log")
    config = root / "config.yaml"
    config.write_text(
        yaml.safe_dump(
            {
                "version": 1,
                "engine": {
                    "headless": True,
                    "account_server_url": server_url,
                    "subconscious_enabled": False,
                    "hive": {
                        "node_name": name,
                        "force_relay": relay,
                        "relay_enabled": True,
                        "direct_timeout_seconds": 5.0,
                    },
                },
            }
        ),
        encoding="utf-8",
    )
    command = [
        sys.executable, "-m", "subconscious_engine", "start", "--dev", "--port", "0", "--no-tray",
        "--data-dir", str(root / "data"), "--config", str(config),
    ]
    log = open(engine.log_path, "w", encoding="utf-8")  # noqa: SIM115
    flags = subprocess.CREATE_NEW_PROCESS_GROUP if sys.platform == "win32" else 0
    engine.process = subprocess.Popen(  # noqa: S603
        command, cwd=str(root), env=engine_environment(root, server_url),
        stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, creationflags=flags,
    )
    engine.pid = engine.process.pid
    try:
        runtime = engine.data_dir / "runtime.json"

        def read_runtime() -> bool:
            info = json.loads(runtime.read_text(encoding="utf-8"))
            engine.url = f"http://{info['host']}:{info['port']}"
            engine.token = info["token"]
            return httpx.get(engine.url + "/api/v1/health", timeout=3).status_code == 200

        _wait(read_runtime, timeout, f"{name} to listen", engine.process)
        if sign_in:
            login = httpx.post(
                engine.url + "/api/v1/account/login", headers=engine.headers, timeout=60,
                json={"email": account["email"], "password": account["password"], "device_name": name},
            )
            if login.status_code != 200:
                raise RuntimeError(f"{name} could not sign in: {login.status_code} {login.text[:300]}")

            def enrolled() -> bool:
                snapshot = engine.get("/api/v1/hive/nodes").json()
                node_id = snapshot.get("node_id")
                local = next((n for n in snapshot.get("nodes", []) if n.get("local")), None)
                if snapshot.get("state") == "running" and node_id and local and local.get("online"):
                    engine.node_id = node_id
                    return True
                return False

            _wait(enrolled, timeout, f"{name} to enrol and come online", engine.process)
    except Exception as error:
        tail = engine.log_tail()
        engine.stop()
        raise RuntimeError(f"engine {name} failed to start: {error}\n--- engine log ---\n{tail}") from error
    return engine
