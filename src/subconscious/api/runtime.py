""" Runtime discovery + local auth for the engine API.

    When the API starts it writes a ``runtime.json`` file into the engine's data
    directory describing how to reach it (port) and a per-session bearer token.
    Local clients (the VS Code extension, future CLIs) read this file to connect.

    The API binds to loopback only and requires the token, so other users/processes
    on the machine cannot drive the engine.
"""
from __future__ import annotations

import os
import json
import socket
import secrets
import logging
import pathlib


# Logging and env setup
RUNTIME_FILENAME = "runtime.json"
logger = logging.getLogger("subconscious")


def generate_token() -> str:
  """ Return a fresh URL-safe local API token """
  return secrets.token_urlsafe(32)

def find_free_port(preferred: int = 8771) -> int:
  """ Return a usable loopback port. Try *preferred* first; fall back to an
      OS-assigned ephemeral port if it's taken.
  """
  for candidate in (preferred, 0):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
      try:
        s.bind(("127.0.0.1", candidate))
        return s.getsockname()[1]
      except OSError:
        continue
  # Should be unreachable: port 0 always succeeds.
  raise RuntimeError("Unable to allocate a loopback port for the engine API.")

def runtime_path(data_dir: pathlib.Path) -> pathlib.Path:
  return pathlib.Path(data_dir) / RUNTIME_FILENAME

def write_runtime_file(
  data_dir: pathlib.Path,
  *,
  port: int,
  token: str,
  version: str,
  node_id: str | None = None,
) -> pathlib.Path:
  """Persist connection details for local clients and return the path."""
  path = runtime_path(data_dir)
  path.parent.mkdir(parents=True, exist_ok=True)
  payload = {
    "host": "127.0.0.1",
    "port": port,
    "token": token,
    "pid": os.getpid(),
    "version": version,
    "node_id": node_id,
  }
  # Write atomically-ish: write temp then replace.
  tmp = path.with_suffix(".json.tmp")
  tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
  tmp.replace(path)
  logger.info("Engine API discovery file written: %s (port %s)", path, port)
  return path


def remove_runtime_file(data_dir: pathlib.Path) -> None:
  """ Delete the discovery file on shutdown """
  try:
    runtime_path(data_dir).unlink(missing_ok=True)
  except OSError as exc:
    logger.debug("Could not remove runtime file: %s", exc)
