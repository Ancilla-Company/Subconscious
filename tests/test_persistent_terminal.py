"""
Unit tests for persistent terminal sessions in subconscious.tools.terminal
"""

import pytest
import asyncio
from subconscious.desktop_tools.terminal import open_terminal_session, run_in_session, close_terminal_session

@pytest.mark.async_io
async def test_terminal_session_lifecycle(ctx):
  # 1. Open session
  open_result = await open_terminal_session(ctx)
  assert "Session" in open_result
  assert "started" in open_result
  
  session_id = open_result.split(" ")[1]
  
  try:
    # 2. Run command in session
    # We use 'echo' which is standard
    run_result = await run_in_session(ctx, session_id, "echo hello_persistent")
    assert run_result["exit_code"] == 0
    # persistent terminal output might be messy, but should contain our echo
    assert "hello_persistent" in run_result["stdout"]
    
    # 3. Test state persistence (setting an env var)
    import sys
    if sys.platform == "win32":
      await run_in_session(ctx, session_id, "set TEST_VAR=persistent_val")
      check_result = await run_in_session(ctx, session_id, "echo %TEST_VAR%")
    else:
      await run_in_session(ctx, session_id, "export TEST_VAR=persistent_val")
      check_result = await run_in_session(ctx, session_id, "echo $TEST_VAR")
      
    assert "persistent_val" in check_result["stdout"]

  finally:
    # 4. Close session
    close_result = await close_terminal_session(ctx, session_id)
    assert "closed" in close_result
    assert session_id in close_result

async def test_run_in_nonexistent_session(ctx):
  result = await run_in_session(ctx, "invalid-session-id", "echo hi")
  assert "not found" in result["stderr"]

async def test_close_nonexistent_session(ctx):
  result = await close_terminal_session(ctx, "invalid-session-id")
  assert "not found" in result
