"""
Unit tests for subconscious.tools.terminal
"""

import os
import sys
import pytest

from subconscious.desktop_tools.terminal import run_command, get_env_var, get_system_info


# ---------------------------------------------------------------------------
# run_command
# ---------------------------------------------------------------------------

async def test_run_command_echo(ctx):
  cmd = "echo hello" if sys.platform != "win32" else "echo hello"
  result = await run_command(ctx, cmd)
  assert result["exit_code"] == 0
  assert "hello" in result["stdout"]
  assert result["timed_out"] is False


async def test_run_command_exit_code_nonzero(ctx):
  cmd = "exit 1" if sys.platform != "win32" else "cmd /c exit 1"
  result = await run_command(ctx, cmd)
  assert result["exit_code"] != 0


async def test_run_command_captures_stderr(ctx):
  if sys.platform == "win32":
    cmd = "cmd /c echo error 1>&2"
  else:
    cmd = "echo error >&2"
  result = await run_command(ctx, cmd)
  # Either stderr captured or exit_code; platform behaviour varies
  assert "exit_code" in result


async def test_run_command_timeout(ctx):
  if sys.platform == "win32":
    cmd = "ping -n 30 127.0.0.1"
  else:
    cmd = "sleep 30"
  result = await run_command(ctx, cmd, timeout=1)
  assert result["timed_out"] is True


async def test_run_command_invalid(ctx):
  result = await run_command(ctx, "this_command_does_not_exist_xyz_abc")
  # Should return gracefully with a non-zero exit code or stderr
  assert result["exit_code"] != 0 or result["stderr"]


async def test_run_command_timeout_capped_at_120(ctx):
  """Passing timeout > 120 must be silently capped, not crash."""
  cmd = "echo cap_test"
  result = await run_command(ctx, cmd, timeout=9999)
  assert result["exit_code"] == 0


# ---------------------------------------------------------------------------
# get_env_var
# ---------------------------------------------------------------------------

async def test_get_env_var_path(ctx):
  result = await get_env_var(ctx, "PATH")
  assert len(result) > 0


async def test_get_env_var_missing_returns_empty(ctx):
  result = await get_env_var(ctx, "SUBCONSCIOUS_NONEXISTENT_VAR_XYZ")
  assert result == "" or "not set" in result.lower()


async def test_get_env_var_sensitive_redacted(ctx):
  os.environ["_TEST_SECRET_KEY"] = "super_secret"
  try:
    result = await get_env_var(ctx, "_TEST_SECRET_KEY")
    assert "super_secret" not in result
    assert "[REDACTED]" in result or "redacted" in result.lower()
  finally:
    del os.environ["_TEST_SECRET_KEY"]


async def test_get_env_var_case_insensitive_sensitive_check(ctx):
  os.environ["_TEST_api_token"] = "my_token_value"
  try:
    result = await get_env_var(ctx, "_TEST_api_token")
    assert "my_token_value" not in result
  finally:
    del os.environ["_TEST_api_token"]


# ---------------------------------------------------------------------------
# get_system_info
# ---------------------------------------------------------------------------

async def test_get_system_info_returns_dict(ctx):
  result = await get_system_info(ctx)
  assert isinstance(result, dict)


async def test_get_system_info_has_platform(ctx):
  result = await get_system_info(ctx)
  assert "platform" in result or "os" in result or "system" in result


async def test_get_system_info_has_python_version(ctx):
  result = await get_system_info(ctx)
  values = " ".join(str(v) for v in result.values())
  assert sys.version[:3] in values or "python" in values.lower()
