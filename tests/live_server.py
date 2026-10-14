"""Launcher for the live hive test (``test_hive_live.py``).

Two roles, one file:

* imported by the test (engine python): builds a throw-away server environment,
  seeds accounts and starts/stops the real ``subconscious-server`` app as a
  subprocess;
* run as a script with the SERVER venv python: ``seed`` creates the schema and
  two accounts through the server's own models and jwt service, ``serve`` runs
  the unmodified FastAPI app with uvicorn.

Nothing here is committed with a secret: the JWT secret, the Fernet key, the
SQLite file, the LMDB directory and every token are generated at run time inside
a temporary directory. The server runs with ``APP_ENV=development`` (so it
creates its own schema and LMDB) and a dummy ``SMTP_HOST`` that only satisfies
the start-up configuration check: no mail is ever sent.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import secrets
import socket
import subprocess
import sys
import time
import urllib.request
import uuid
from pathlib import Path
from typing import Any

SERVER_DIR = Path(os.environ.get("SC_SERVER_DIR") or Path(__file__).resolve().parents[2] / "subconscious-server")
SERVER_PYTHON = SERVER_DIR / ".venv" / "Scripts" / "python.exe"
_KEEP_ENV = (
    "SYSTEMROOT", "SYSTEMDRIVE", "WINDIR", "PATH", "PATHEXT", "COMSPEC", "TEMP", "TMP",
    "USERPROFILE", "APPDATA", "LOCALAPPDATA", "HOMEDRIVE", "HOMEPATH", "PROCESSOR_ARCHITECTURE",
)


def server_available() -> bool:
    return SERVER_PYTHON.exists() and (SERVER_DIR / "app" / "main.py").exists()


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def server_environment(root: Path, access_token_minutes: int = 15) -> dict[str, str]:
    """A minimal environment for the server: random secrets, files under ``root``."""
    data = root / "data"
    env = {key: os.environ[key] for key in _KEEP_ENV if key in os.environ}
    env.update(
        {
            "PYTHONPATH": str(SERVER_DIR),
            "PYTHONIOENCODING": "utf-8",
            "APP_ENV": "development",
            "DATA_DIR": str(data),
            "DATABASE_URL": "sqlite+aiosqlite:///" + (data / "server.db").as_posix(),
            "LMDB_PATH": str(data / "lmdb"),
            "LMDB_MAP_SIZE": str(64 * 1024 * 1024),
            "TOKEN_ENCRYPTION_KEY": base64.urlsafe_b64encode(secrets.token_bytes(32)).decode(),
            "JWT_SECRET_KEY": secrets.token_urlsafe(48),
            "JWT_ACCESS_TOKEN_EXPIRE_MINUTES": str(access_token_minutes),
            "COOKIE_SECURE": "false",
            "SMTP_HOST": "127.0.0.1",  # start-up check only; no mail is sent
            "SIGNALING_ENABLED": "true",
            "SIGNAL_RELAY_ENABLED": "true",
            "TURN_ENABLED": "false",
            "TURN_URIS": "",
            "TURN_SHARED_SECRETS": "",
            "STUN_URIS": "",  # no external network
        }
    )
    return env


def _run_server_python(root: Path, env: dict[str, str], *args: str, **kwargs: Any) -> Any:
    return subprocess.Popen(
        [str(SERVER_PYTHON), str(Path(__file__).resolve()), *args],
        cwd=str(root),  # a cwd without a .env file, so nothing else leaks in
        env=env,
        **kwargs,
    )


def seed_accounts(root: Path, env: dict[str, str]) -> dict[str, dict[str, str]]:
    """Create accounts A and B in the server DB; returns ids, emails and refresh tokens."""
    root.mkdir(parents=True, exist_ok=True)
    process = _run_server_python(root, env, "seed", stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = process.communicate(timeout=90)
    if process.returncode != 0:
        raise RuntimeError(f"seeding the server failed: {err[-2000:]}")
    return json.loads(out.strip().splitlines()[-1])


class RunningServer:
    def __init__(self, root: Path, access_token_minutes: int = 15) -> None:
        self.root = root
        self.port = free_port()
        self.env = server_environment(root, access_token_minutes)
        self.accounts: dict[str, dict[str, str]] = {}
        self.process: subprocess.Popen[str] | None = None
        self._log: Any = None

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def start(self) -> "RunningServer":
        self.accounts = seed_accounts(self.root, self.env)
        self._log = open(self.root / "server.log", "w", encoding="utf-8")  # noqa: SIM115
        self.process = _run_server_python(
            self.root, self.env, "serve", "--port", str(self.port), stdout=self._log, stderr=subprocess.STDOUT, text=True
        )
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("the server exited during start-up:\n" + self.log_tail())
            try:
                with urllib.request.urlopen(self.url + "/health", timeout=1) as response:  # noqa: S310 - loopback
                    if response.status == 200:
                        return self
            except OSError:
                time.sleep(0.2)
        self.stop()
        raise RuntimeError("the server did not become ready:\n" + self.log_tail())

    def log_tail(self) -> str:
        try:
            return (self.root / "server.log").read_text(encoding="utf-8", errors="replace")[-3000:]
        except OSError:
            return ""

    def stop(self) -> None:
        process, self.process = self.process, None
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        if self._log is not None:
            self._log.close()
            self._log = None


# --- script side (server venv) ------------------------------------------------------


async def _seed() -> dict[str, dict[str, str]]:
    import app.models.admin  # noqa: F401  (register every table on Base.metadata)
    import app.models.node  # noqa: F401
    import app.models.webhook  # noqa: F401
    from app.database import AsyncSessionLocal, init_db
    from app.lmdb_client import close_lmdb, init_lmdb
    from app.models.user import User
    from app.services.jwt_service import create_access_token, create_refresh_token

    await init_db()
    await init_lmdb()
    accounts: dict[str, dict[str, str]] = {}
    try:
        async with AsyncSessionLocal() as db:
            users = {
                label: User(
                    id=uuid.uuid4(),
                    email=f"live-{label.lower()}-{secrets.token_hex(4)}@example.com",
                    display_name=f"Live {label}",
                    email_verified=True,
                )
                for label in ("A", "B")
            }
            db.add_all(users.values())
            await db.commit()
        for label, user in users.items():
            access, _ = create_access_token(str(user.id), user.email)
            # Independent refresh-token families: engines sharing one family would trip
            # the server's refresh-token reuse detection.
            tokens = [await create_refresh_token(str(user.id)) for _ in range(4)]
            accounts[label] = {
                "user_id": str(user.id),
                "email": user.email,
                "access_token": access,
                "refresh_token": tokens[0],
                "refresh_tokens": tokens,
            }
    finally:
        await close_lmdb()
    return accounts


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("seed", "serve"))
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    if args.command == "seed":
        print(json.dumps(asyncio.run(_seed())))
        return
    import uvicorn

    uvicorn.run("app.main:app", host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    sys.exit(main())
