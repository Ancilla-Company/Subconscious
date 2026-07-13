"""
Unit / example tests for `Engine._resolve_ambient_context` and its wiring into
`stream_chat` (spec: system-information-context, task 8.3).

`_resolve_ambient_context` decides whether the ambient system-information block
is injected into the agent's system prompt at build time. It returns the
formatted context only when the privacy toggle is enabled AND a system-info
service is available, and is guarded so any failure yields None (build without
ambient context) rather than propagating.

Covers:
  - Toggle enabled + profile available -> formatted context returned and passed
    to build_agent (Req 6.1).
  - Toggle disabled -> None, so the agent is built without ambient context
    (Req 7.4).
  - Service unavailable (system_info is None, e.g. init failed) -> None
    (Req 8.1).
  - format_ambient_context raises -> None and the failure is logged (Reqs 8.1,
    8.2).

These build the Engine via __new__ to avoid standing up the full startup
pipeline, mirroring test_engine_init_system_info.py and
test_engine_share_system_context.py.
"""

import types

import pytest

from subconscious.engine import Engine


def _make_engine() -> Engine:
  """Construct an Engine with just enough state for _resolve_ambient_context."""
  engine = Engine.__new__(Engine)
  engine._share_system_context = True
  engine.system_info = None
  return engine


class _FakeSystemInfo:
  """Minimal stand-in for SystemInformationService.format_ambient_context."""

  def __init__(self, context="<system_information>...</system_information>"):
    self._context = context
    self.calls = 0

  def format_ambient_context(self) -> str:
    self.calls += 1
    return self._context


class _RaisingSystemInfo:
  """A service whose formatting raises, to exercise the guard."""

  def format_ambient_context(self) -> str:
    raise RuntimeError("format blew up")


# ---------------------------------------------------------------------------
# Toggle enabled + profile available (Req 6.1)
# ---------------------------------------------------------------------------

class TestToggleEnabled:
  async def test_returns_formatted_context_when_enabled_and_available(self):
    engine = _make_engine()
    engine._share_system_context = True
    engine.system_info = _FakeSystemInfo("AMBIENT BLOCK")

    result = await engine._resolve_ambient_context()

    assert result == "AMBIENT BLOCK"
    assert engine.system_info.calls == 1

  async def test_empty_string_context_is_passed_through(self):
    """An empty formatted context is returned as-is; build_agent treats an
    empty string as "no context" so no special-casing is needed here."""
    engine = _make_engine()
    engine._share_system_context = True
    engine.system_info = _FakeSystemInfo("")

    result = await engine._resolve_ambient_context()

    assert result == ""


# ---------------------------------------------------------------------------
# Toggle disabled (Req 7.4)
# ---------------------------------------------------------------------------

class TestToggleDisabled:
  async def test_returns_none_when_toggle_disabled(self):
    engine = _make_engine()
    engine._share_system_context = False
    engine.system_info = _FakeSystemInfo("SHOULD NOT BE USED")

    result = await engine._resolve_ambient_context()

    assert result is None

  async def test_service_not_consulted_when_disabled(self):
    """When disabled, formatting is skipped entirely (no work, no PII risk)."""
    engine = _make_engine()
    engine._share_system_context = False
    engine.system_info = _FakeSystemInfo()

    await engine._resolve_ambient_context()

    assert engine.system_info.calls == 0


# ---------------------------------------------------------------------------
# Service unavailable (Req 8.1)
# ---------------------------------------------------------------------------

class TestServiceUnavailable:
  async def test_returns_none_when_system_info_is_none(self):
    engine = _make_engine()
    engine._share_system_context = True
    engine.system_info = None

    result = await engine._resolve_ambient_context()

    assert result is None


# ---------------------------------------------------------------------------
# Formatting failure is guarded (Reqs 8.1, 8.2)
# ---------------------------------------------------------------------------

class TestFormatFailureGuarded:
  async def test_returns_none_when_format_raises(self):
    engine = _make_engine()
    engine._share_system_context = True
    engine.system_info = _RaisingSystemInfo()

    # Must not propagate: chat must keep working (Req 8.2).
    result = await engine._resolve_ambient_context()

    assert result is None

  async def test_failure_is_logged(self, caplog):
    engine = _make_engine()
    engine._share_system_context = True
    engine.system_info = _RaisingSystemInfo()

    with caplog.at_level("ERROR", logger="subconscious"):
      await engine._resolve_ambient_context()

    assert any("Failed to resolve ambient system context" in r.message
               for r in caplog.records)


# ---------------------------------------------------------------------------
# stream_chat wiring: resolved context is passed to build_agent
# ---------------------------------------------------------------------------

class TestStreamChatWiring:
  async def test_stream_chat_passes_ambient_context_to_build_agent(self, monkeypatch):
    """stream_chat resolves ambient context and forwards it to build_agent.

    The chat pipeline is heavily stubbed so the test focuses purely on the
    build_agent call receiving the resolved ambient context. An echo-style
    agent short-circuits the streaming path.
    """
    from subconscious.agent import EchoProvider

    engine = Engine.__new__(Engine)
    engine._share_system_context = True
    engine.system_info = _FakeSystemInfo("RESOLVED CONTEXT")

    captured = {}

    class _FakeAgentManager:
      def get_best_model_cfg(self):
        return {"provider": "openai", "model": "gpt-4o"}

      def build_agent(self, model_cfg, tools=None, ambient_context=None):
        captured["ambient_context"] = ambient_context
        # Return an EchoProvider so stream_chat takes the simple stream path.
        return EchoProvider()

    class _FakeToolRegistry:
      def get_tools_for_config(self, cfg):
        return []

    engine.agent_manager = _FakeAgentManager()
    engine.tool_registry = _FakeToolRegistry()
    engine.config = types.SimpleNamespace(data_dir="/tmp")
    engine.db = None

    async def _fake_load_thread_messages(thread_id):
      return []

    async def _fake_resolve_tools_config(workspace_id, thread_id):
      return {}

    monkeypatch.setattr(engine, "load_thread_messages", _fake_load_thread_messages)
    monkeypatch.setattr(engine, "resolve_tools_config", _fake_resolve_tools_config)

    chunks = []
    async for chunk in engine.stream_chat(content="hi", thread_id=1):
      chunks.append(chunk)

    assert captured["ambient_context"] == "RESOLVED CONTEXT"

  async def test_stream_chat_passes_none_when_toggle_disabled(self, monkeypatch):
    """With the toggle disabled, build_agent receives ambient_context=None."""
    from subconscious.agent import EchoProvider

    engine = Engine.__new__(Engine)
    engine._share_system_context = False
    engine.system_info = _FakeSystemInfo("SHOULD NOT BE USED")

    captured = {}

    class _FakeAgentManager:
      def get_best_model_cfg(self):
        return {"provider": "openai", "model": "gpt-4o"}

      def build_agent(self, model_cfg, tools=None, ambient_context=None):
        captured["ambient_context"] = ambient_context
        return EchoProvider()

    class _FakeToolRegistry:
      def get_tools_for_config(self, cfg):
        return []

    engine.agent_manager = _FakeAgentManager()
    engine.tool_registry = _FakeToolRegistry()
    engine.config = types.SimpleNamespace(data_dir="/tmp")
    engine.db = None

    async def _fake_load_thread_messages(thread_id):
      return []

    async def _fake_resolve_tools_config(workspace_id, thread_id):
      return {}

    monkeypatch.setattr(engine, "load_thread_messages", _fake_load_thread_messages)
    monkeypatch.setattr(engine, "resolve_tools_config", _fake_resolve_tools_config)

    async for _ in engine.stream_chat(content="hi", thread_id=1):
      pass

    assert captured["ambient_context"] is None
