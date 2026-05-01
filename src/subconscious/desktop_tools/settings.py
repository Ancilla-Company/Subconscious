"""
Settings tools — Modify application-wide settings like theme mode.
"""

from typing import Optional
from pydantic_ai import RunContext
from . import EngineContext

async def get_app_setting(ctx: RunContext[EngineContext], key: str, tag: str = "system") -> str:
  """
  Retrieve an application setting value.

  Args:
    key: The setting key (e.g., 'mode', 'language').
    tag: The setting tag (default 'system').
  """
  if ctx.deps.engine is None:
    return "Engine instance not available in context."
  val = await ctx.deps.engine.get_setting(key, tag)
  return val or f"Setting '{key}' not found."


async def update_app_setting(ctx: RunContext[EngineContext], key: str, value: str, tag: str = "system") -> str:
  """
  Update an application setting value. Registered UI callbacks (e.g. Flet page
  theme) are notified immediately so the change is reflected in real-time.

  Args:
    key: The setting key (e.g., 'mode').
    value: The new value for the setting (e.g., 'dark', 'light', 'auto').
    tag: The setting tag (default 'system').
  """
  if ctx.deps.engine is None:
    return "Engine instance not available in context."
  await ctx.deps.engine.update_setting(key, value, tag)
  return f"Setting '{key}' updated to '{value}'."


async def set_theme_mode(ctx: RunContext[EngineContext], mode: str) -> str:
  """
  Set the application theme mode (dark, light, or auto).
  
  Args:
    mode: The theme mode to set. Must be one of: 'dark', 'light', 'auto'.
  """
  if mode not in ["dark", "light", "auto"]:
    return "Invalid mode. Choose from 'dark', 'light', or 'auto'."
  
  return await update_app_setting(ctx, "mode", mode)


TOOLS = [get_app_setting, update_app_setting, set_theme_mode]
