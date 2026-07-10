"""
Unit / example tests for the `share_system_context` privacy toggle plumbing on
the Engine (spec: system-information-context, task 8.1).

Covers:
  - Init default (Req 7.2): empty AppState -> setting created as "true" and the
    in-memory cache is seeded True.
  - Preserve existing value (Req 7.3): a stored value survives init_settings and
    seeds the cache accordingly.
  - Callback update (Req 7.5): updating the setting refreshes the in-memory
    cache so agents built afterward honour the new value.
  - The shared `_as_bool` coercion helper.

These use the in-memory SQLite `db` fixture from conftest and build the Engine
via __new__ to avoid standing up the full startup pipeline.
"""

import pytest_asyncio
import pytest
from sqlalchemy import select, delete

from subconscious.engine import Engine
from subconscious.db.models import AppState


@pytest_asyncio.fixture(autouse=True)
async def _clean_app_state(db):
  """Isolate each test from the session-scoped in-memory DB.

  The shared `async_engine`/`db` fixtures persist rows across the whole test
  session, so without this cleanup a `share_system_context` row created by one
  test would leak into the next and defeat the "absent"/"existing" setups these
  tests rely on. Clearing the table before each test gives a clean AppState.
  """
  async with db.get_session() as session:
    await session.execute(delete(AppState))
    await session.commit()
  yield


def _make_engine(db) -> Engine:
  """Construct an Engine wired to the in-memory DB without running __init__."""
  engine = Engine.__new__(Engine)
  engine.db = db
  engine._setting_callbacks = {}
  return engine


async def _get_setting_row(db, key: str, tag: str = "system"):
  async with db.get_session() as session:
    return await session.scalar(
      select(AppState).where(AppState.key == key, AppState.tag == tag)
    )


# ---------------------------------------------------------------------------
# Req 7.2 — default created when absent
# ---------------------------------------------------------------------------

class TestInitDefault:
  async def test_creates_setting_with_true_default(self, db):
    """With an empty AppState, init_settings creates share_system_context=true."""
    engine = _make_engine(db)

    await engine.init_settings()

    row = await _get_setting_row(db, "share_system_context")
    assert row is not None
    assert row.value == "true"
    assert row.tag == "system"

  async def test_seeds_cache_enabled_by_default(self, db):
    """After init_settings on an empty store, the in-memory cache is True."""
    engine = _make_engine(db)

    await engine.init_settings()

    assert engine._share_system_context is True

  async def test_registers_callback(self, db):
    """init_settings registers the change callback for the setting key."""
    engine = _make_engine(db)

    await engine.init_settings()

    callbacks = engine._setting_callbacks.get("share_system_context", [])
    assert engine._on_share_system_context_changed in callbacks


# ---------------------------------------------------------------------------
# Req 7.3 — existing value preserved
# ---------------------------------------------------------------------------

class TestPreserveExistingValue:
  async def test_existing_value_not_overwritten(self, db):
    """A pre-existing stored value survives init_settings unchanged."""
    async with db.get_session() as session:
      session.add(AppState(key="share_system_context", value="false", tag="system"))
      await session.commit()

    engine = _make_engine(db)
    await engine.init_settings()

    row = await _get_setting_row(db, "share_system_context")
    assert row.value == "false"

  async def test_cache_seeded_from_existing_value(self, db):
    """The cache is seeded from the preserved stored value (disabled)."""
    async with db.get_session() as session:
      session.add(AppState(key="share_system_context", value="false", tag="system"))
      await session.commit()

    engine = _make_engine(db)
    await engine.init_settings()

    assert engine._share_system_context is False

  async def test_malformed_stored_value_falls_back_to_default(self, db):
    """A malformed stored value is coerced to the default (True) when seeding."""
    async with db.get_session() as session:
      session.add(AppState(key="share_system_context", value="banana", tag="system"))
      await session.commit()

    engine = _make_engine(db)
    await engine.init_settings()

    # Stored value is preserved as-is, but the cache falls back to the default.
    row = await _get_setting_row(db, "share_system_context")
    assert row.value == "banana"
    assert engine._share_system_context is True


# ---------------------------------------------------------------------------
# Req 7.5 — callback updates the in-memory cache
# ---------------------------------------------------------------------------

class TestCallbackUpdate:
  async def test_callback_updates_cache_to_disabled(self, db):
    """The callback flips the cached toggle when the setting is disabled."""
    engine = _make_engine(db)
    await engine.init_settings()
    assert engine._share_system_context is True

    await engine._on_share_system_context_changed(
      "share_system_context", "false", "system"
    )
    assert engine._share_system_context is False

  async def test_callback_updates_cache_to_enabled(self, db):
    """The callback flips the cached toggle back to enabled."""
    engine = _make_engine(db)
    await engine.init_settings()
    engine._share_system_context = False

    await engine._on_share_system_context_changed(
      "share_system_context", "true", "system"
    )
    assert engine._share_system_context is True

  async def test_registered_callback_refreshes_cache_on_notify(self, db):
    """update_setting persists the new value AND refreshes the cache via the
    registered callback (Req 7.5), end-to-end through the real DB upsert.

    This exercises the full path — the (key, tag) composite-unique upsert plus
    the callback notify loop — which previously failed because app_state had no
    valid ON CONFLICT target.
    """
    engine = _make_engine(db)
    await engine.init_settings()
    assert engine._share_system_context is True

    await engine.update_setting("share_system_context", "false", "system")

    # The value was persisted via the upsert...
    row = await _get_setting_row(db, "share_system_context")
    assert row.value == "false"
    # ...and the registered callback refreshed the in-memory cache.
    assert engine._share_system_context is False

  async def test_update_setting_upserts_in_place_without_duplicating(self, db):
    """Repeated update_setting calls update the existing row in place rather
    than inserting duplicate (key, tag) rows (composite-unique upsert)."""
    engine = _make_engine(db)
    await engine.init_settings()

    await engine.update_setting("share_system_context", "false", "system")
    await engine.update_setting("share_system_context", "true", "system")

    async with db.get_session() as session:
      rows = (
        await session.scalars(
          select(AppState).where(
            AppState.key == "share_system_context", AppState.tag == "system"
          )
        )
      ).all()

    assert len(rows) == 1
    assert rows[0].value == "true"


# ---------------------------------------------------------------------------
# _as_bool helper
# ---------------------------------------------------------------------------

class TestAsBool:
  @pytest.mark.parametrize("value", ["true", "True", "1", "yes", "on", " TRUE "])
  def test_truthy_strings(self, value):
    assert Engine._as_bool(value) is True

  @pytest.mark.parametrize("value", ["false", "False", "0", "no", "off", " OFF "])
  def test_falsey_strings(self, value):
    assert Engine._as_bool(value) is False

  def test_none_falls_back_to_default(self):
    assert Engine._as_bool(None) is True
    assert Engine._as_bool(None, default=False) is False

  @pytest.mark.parametrize("value", ["banana", "", "maybe", "2"])
  def test_unrecognized_falls_back_to_default(self, value):
    assert Engine._as_bool(value, default=True) is True
    assert Engine._as_bool(value, default=False) is False

  def test_bool_passthrough(self):
    assert Engine._as_bool(True) is True
    assert Engine._as_bool(False) is False
