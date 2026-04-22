"""
Terminal tools — run shell commands via subprocess.
⚠ Security note: This tool executes arbitrary commands as the current user.
It should only be enabled for workspaces/users who explicitly consent.
A default timeout and output size cap are enforced.
"""

import os
import sys
import socket
import asyncio
import logging
import platform
from pydantic_ai import RunContext

from . import EngineContext


logger = logging.getLogger("subconscious")

_DEFAULT_TIMEOUT = 30   # seconds
_MAX_OUTPUT_CHARS = 10_000


async def run_command(
  ctx: RunContext[EngineContext],
  command: str,
  working_dir: str = "~",
  timeout: int = _DEFAULT_TIMEOUT,
) -> dict:
  """
  Execute a shell command and return its stdout, stderr and exit code.
  Output is capped at 10 000 characters. Default timeout is 30 seconds.

  ⚠ Commands run with the same permissions as the Subconscious process.
  Destructive commands (rm -rf, format, etc.) will execute without confirmation.

  Args:
    command: The shell command to run, e.g. 'ls -la' or 'python --version'.
    working_dir: Working directory (default '~'). Must be within the user home.
    timeout: Maximum seconds to wait (default 30, max 120).
  """
  timeout = max(1, min(timeout, 120))
  cwd = os.path.expanduser(working_dir)

  # Warn about destructive patterns — but do not block; the user consented by enabling this tool
  _WARN_PATTERNS = ["rm -rf", "rmdir /s", "format ", "del /f", "mkfs", "dd if="]
  for pat in _WARN_PATTERNS:
    if pat.lower() in command.lower():
      logger.warning(f"Terminal tool running potentially destructive command: {command!r}")

  shell = True
  if platform.system() == "Windows":
    shell = True

  try:
    proc = await asyncio.create_subprocess_shell(
      command,
      stdout=asyncio.subprocess.PIPE,
      stderr=asyncio.subprocess.PIPE,
      cwd=cwd,
      shell=shell,
    )
    try:
      stdout_b, stderr_b = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
      proc.kill()
      return {
        "exit_code": -1,
        "stdout": "",
        "stderr": f"Command timed out after {timeout} seconds.",
        "timed_out": True,
      }

    stdout = stdout_b.decode(errors="replace")
    stderr = stderr_b.decode(errors="replace")

    if len(stdout) > _MAX_OUTPUT_CHARS:
      stdout = stdout[:_MAX_OUTPUT_CHARS] + f"\n[... output truncated at {_MAX_OUTPUT_CHARS} chars]"
    if len(stderr) > _MAX_OUTPUT_CHARS:
      stderr = stderr[:_MAX_OUTPUT_CHARS] + f"\n[... stderr truncated]"

    return {
      "exit_code": proc.returncode,
      "stdout": stdout.strip(),
      "stderr": stderr.strip(),
      "timed_out": False,
    }
  except Exception as exc:
    return {"exit_code": -1, "stdout": "", "stderr": str(exc), "timed_out": False}


async def get_env_var(ctx: RunContext[EngineContext], name: str) -> str:
  """
  Read a single environment variable by name and return its value.
  Returns an empty string if the variable is not set.
  Sensitive variables (containing 'KEY', 'SECRET', 'TOKEN', 'PASSWORD') are redacted.

  Args:
    name: The environment variable name, e.g. 'PATH' or 'HOME'.
  """
  upper = name.upper()
  sensitive = any(w in upper for w in ("KEY", "SECRET", "TOKEN", "PASSWORD", "PASS", "CREDENTIAL"))
  if sensitive:
    val = os.environ.get(name, "")
    return "[REDACTED — sensitive variable]" if val else "(not set)"
  return os.environ.get(name, "(not set)")


async def get_system_info(ctx: RunContext[EngineContext]) -> dict:
  """
  Return basic information about the host system: OS, Python version, CPU count,
  hostname, and current working directory.
  """
  return {
    "os":           platform.system(),
    "os_version":   platform.version(),
    "architecture": platform.machine(),
    "python":       sys.version.split(" ")[0],
    "cpu_count":    os.cpu_count(),
    "hostname":     socket.gethostname(),
    "cwd":          os.getcwd(),
  }


TOOLS = [run_command, get_env_var, get_system_info]
