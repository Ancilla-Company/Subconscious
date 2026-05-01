"""
Unit tests for the platform tool registry hierarchy.

These integration-level tests verify the inheritance relationships between
BaseToolRegistry, DesktopToolRegistry, MobileToolRegistry, and ServerToolRegistry:
  - All registries are proper subclasses of BaseToolRegistry
  - Platform registries are strict supersets of the base
  - No platform registry leaks another platform's exclusive tools
  - EngineContext imported from any registry is the same class
"""

import pytest

from subconscious.tools import BaseToolRegistry, EngineContext as BaseCtx
from subconscious.mobile_tools import ToolRegistry as MobileRegistry, EngineContext as MobileCtx
from subconscious.server_tools import ToolRegistry as ServerRegistry, EngineContext as ServerCtx
from subconscious.desktop_tools import ToolRegistry as DesktopRegistry, EngineContext as DesktopCtx


BASE_SLUGS = frozenset({"time", "calculator", "weather", "todo", "memory", "notes", "contacts"})
DESKTOP_ONLY = frozenset({"web", "filesystem", "terminal", "clipboard", "images", "settings"})
SERVER_ONLY = frozenset({"web", "filesystem", "terminal", "images", "settings"})  # no clipboard
MOBILE_EXTRA = frozenset({"filesystem", "web_search"})


class TestInheritanceHierarchy:
  def test_desktop_is_base_subclass(self):
    assert issubclass(DesktopRegistry, BaseToolRegistry)

  def test_mobile_is_base_subclass(self):
    assert issubclass(MobileRegistry, BaseToolRegistry)

  def test_server_is_base_subclass(self):
    assert issubclass(ServerRegistry, BaseToolRegistry)


class TestBaseSlugInAllRegistries:
  @pytest.mark.parametrize("RegistryCls", [
    BaseToolRegistry,
    DesktopRegistry,
    MobileRegistry,
    ServerRegistry,
  ])
  def test_base_slugs_present(self, RegistryCls):
    r = RegistryCls()
    missing = BASE_SLUGS - set(r.all_slugs())
    assert not missing, f"{RegistryCls.__name__} missing base slugs: {missing}"


class TestPlatformExclusivity:
  def test_base_has_no_desktop_tools(self):
    r = BaseToolRegistry()
    assert not (DESKTOP_ONLY & set(r.all_slugs()))

  def test_mobile_has_no_terminal_or_clipboard(self):
    r = MobileRegistry()
    forbidden = {"terminal", "clipboard"}
    assert not (forbidden & set(r.all_slugs()))

  def test_server_has_no_clipboard(self):
    r = ServerRegistry()
    assert "clipboard" not in r.all_slugs()

  def test_desktop_has_clipboard_but_mobile_does_not(self):
    desktop = DesktopRegistry()
    mobile = MobileRegistry()
    assert "clipboard" in desktop.all_slugs()
    assert "clipboard" not in mobile.all_slugs()

  def test_desktop_has_terminal_but_mobile_does_not(self):
    desktop = DesktopRegistry()
    mobile = MobileRegistry()
    assert "terminal" in desktop.all_slugs()
    assert "terminal" not in mobile.all_slugs()


class TestEngineContextIdentity:
  """EngineContext re-exported from each registry package must be the same class."""

  def test_desktop_ctx_is_base_ctx(self):
    assert DesktopCtx is BaseCtx

  def test_mobile_ctx_is_base_ctx(self):
    assert MobileCtx is BaseCtx

  def test_server_ctx_is_base_ctx(self):
    assert ServerCtx is BaseCtx


class TestSlugCounts:
  def test_desktop_has_more_slugs_than_base(self):
    base = BaseToolRegistry()
    desktop = DesktopRegistry()
    assert len(desktop.all_slugs()) > len(base.all_slugs())

  def test_mobile_has_more_slugs_than_base(self):
    base = BaseToolRegistry()
    mobile = MobileRegistry()
    assert len(mobile.all_slugs()) > len(base.all_slugs())

  def test_server_has_more_slugs_than_base(self):
    base = BaseToolRegistry()
    server = ServerRegistry()
    assert len(server.all_slugs()) > len(base.all_slugs())

  def test_desktop_has_more_slugs_than_server(self):
    """Desktop > server because desktop adds clipboard."""
    desktop = DesktopRegistry()
    server = ServerRegistry()
    assert len(desktop.all_slugs()) > len(server.all_slugs())
