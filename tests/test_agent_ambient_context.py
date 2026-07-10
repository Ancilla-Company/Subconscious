"""
Property-based and example tests for ambient-context injection into
``AgentManager.build_agent`` (spec: system-information-context, task 7.1).

``build_agent`` composes the final agent system prompt as the model-configured
prompt optionally followed by an ambient-context block. pydantic-ai stores the
static system prompt on the constructed Agent as the ``_system_prompts`` tuple,
so the effective prompt is asserted via ``agent._system_prompts[0]``.

Covered correctness properties (see design.md):
  - Property 10 (Prompt composition & gating): the model prompt is preserved
    unchanged and the ambient context is appended iff a non-empty context is
    supplied; when the context is None/empty the effective prompt equals the
    model prompt alone.
  - Property 11 (Build resilience): build_agent returns a valid Agent for any
    ambient context input (None, "", or an arbitrary string) and never raises
    on account of ambient-context handling.
"""

from hypothesis import given, settings, strategies as st
from pydantic_ai import Agent

from subconscious.agent import AgentManager


DEFAULT_PROMPT = "You are a helpful assistant."


def _manager() -> AgentManager:
  """AgentManager whose build_agent path (openai provider) never touches config."""
  return AgentManager(config=None)  # type: ignore[arg-type]


def _model_cfg(system_prompt) -> dict:
  """A minimal openai model config; Agent construction is fully offline."""
  cfg = {"provider": "openai", "model": "gpt-4o"}
  if system_prompt is not None:
    cfg["system_prompt"] = system_prompt
  return cfg


def _expected_base(raw_system_prompt) -> str:
  """Replicate build_agent's base-prompt derivation for assertion clarity."""
  return (raw_system_prompt or DEFAULT_PROMPT).strip()


def _effective_prompt(agent: Agent) -> str:
  """The static system prompt pydantic-ai stored on the agent."""
  return agent._system_prompts[0]


# ---------------------------------------------------------------------------
# Property 10: Prompt composition and gating
# ---------------------------------------------------------------------------

# Feature: system-information-context, Property 10: For any model-configured
# system prompt and any ambient context string, build_agent produces an agent
# whose effective system prompt contains the original model prompt unchanged
# and, when a non-empty ambient context is supplied, also contains that ambient
# context; when the ambient context is None or empty, the effective system
# prompt equals the model prompt alone.
# Validates: Requirements 6.1, 6.4, 7.4
@settings(max_examples=100, deadline=None)
@given(
  system_prompt=st.one_of(st.none(), st.text(max_size=200)),
  ambient_context=st.one_of(st.none(), st.text(max_size=200)),
)
def test_prompt_composition_and_gating(system_prompt, ambient_context):
  agent = _manager().build_agent(
    _model_cfg(system_prompt), ambient_context=ambient_context
  )

  base = _expected_base(system_prompt)
  effective = _effective_prompt(agent)

  if ambient_context:
    # Non-empty ambient context: model prompt preserved as the prefix and the
    # ambient context appended after a blank-line separator.
    assert effective == f"{base}\n\n{ambient_context}"
    assert effective.startswith(base)
    assert ambient_context in effective
  else:
    # None or empty ambient context: behaviour unchanged, prompt is the base.
    assert effective == base


# ---------------------------------------------------------------------------
# Property 11: Build resilience
# ---------------------------------------------------------------------------

# Feature: system-information-context, Property 11: For any ambient context
# input (a valid string, None, or an empty/handled result), build_agent returns
# a valid Agent and never raises on account of ambient-context handling.
# Validates: Requirements 8.1, 8.2
@settings(max_examples=100, deadline=None)
@given(ambient_context=st.one_of(st.none(), st.text(max_size=200)))
def test_build_agent_resilient_to_any_ambient_context(ambient_context):
  agent = _manager().build_agent(
    _model_cfg("You are a test agent."), ambient_context=ambient_context
  )
  assert isinstance(agent, Agent)


# ---------------------------------------------------------------------------
# Example tests — concrete composition semantics
# ---------------------------------------------------------------------------

class TestAmbientContextExamples:
  def test_default_signature_omits_ambient_context(self):
    """Called without ambient_context, the prompt is the configured prompt."""
    agent = _manager().build_agent(_model_cfg("Base prompt."))
    assert _effective_prompt(agent) == "Base prompt."

  def test_ambient_context_appended_after_blank_line(self):
    """A supplied context is appended after the model prompt with a separator."""
    agent = _manager().build_agent(
      _model_cfg("Base prompt."), ambient_context="<system_information>...</system_information>"
    )
    assert _effective_prompt(agent) == (
      "Base prompt.\n\n<system_information>...</system_information>"
    )

  def test_empty_string_context_leaves_prompt_unchanged(self):
    """An empty ambient context is treated as absent (unchanged behaviour)."""
    agent = _manager().build_agent(_model_cfg("Base prompt."), ambient_context="")
    assert _effective_prompt(agent) == "Base prompt."

  def test_missing_model_prompt_uses_default_then_appends_context(self):
    """When no model prompt is configured, the default is used as the base."""
    agent = _manager().build_agent(_model_cfg(None), ambient_context="AMBIENT")
    assert _effective_prompt(agent) == f"{DEFAULT_PROMPT}\n\nAMBIENT"

  def test_composition_holds_when_tools_attached(self):
    """The same composition applies on the tools/deps build path."""
    def sample_tool() -> str:  # pragma: no cover - never invoked, just registered
      return "ok"

    agent = _manager().build_agent(
      _model_cfg("Base prompt."), tools=[sample_tool], ambient_context="AMBIENT"
    )
    assert isinstance(agent, Agent)
    assert _effective_prompt(agent) == "Base prompt.\n\nAMBIENT"
