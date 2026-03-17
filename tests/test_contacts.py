"""
Unit tests for subconscious.tools.contacts
"""

import pytest
from subconscious.tools.contacts import (
  add_contact,
  list_contacts,
  find_contact,
  update_contact,
  delete_contact,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _make_contact(ctx, name="Alice Smith", email="alice@example.com",
                        phone="555-1234", notes="test contact"):
  return await add_contact(ctx, name=name, email=email, phone=phone, notes=notes)


# ---------------------------------------------------------------------------
# add_contact
# ---------------------------------------------------------------------------

async def test_add_contact_returns_record(ctx):
  result = await _make_contact(ctx)
  assert result["status"] == "ok"
  assert "contact" in result
  assert result["contact"]["name"] == "Alice Smith"


async def test_add_contact_stores_email(ctx):
  result = await add_contact(ctx, name="Bob", email="bob@example.com")
  assert result["contact"]["email"] == "bob@example.com"


async def test_add_contact_optional_fields_empty(ctx):
  result = await add_contact(ctx, name="Minimal")
  assert result["status"] == "ok"
  assert result["contact"]["email"] == ""
  assert result["contact"]["phone"] == ""


# ---------------------------------------------------------------------------
# list_contacts
# ---------------------------------------------------------------------------

async def test_list_contacts_finds_added(ctx):
  await add_contact(ctx, name="ListTest Person", email="list@test.com")
  result = await list_contacts(ctx)
  assert result["status"] == "ok"
  names = [c["name"] for c in result["contacts"]]
  assert "ListTest Person" in names


async def test_list_contacts_sorted_by_name(ctx):
  await add_contact(ctx, name="Zelda")
  await add_contact(ctx, name="Aaron")
  result = await list_contacts(ctx)
  names = [c["name"] for c in result["contacts"]]
  # Aaron must come before Zelda
  assert names.index("Aaron") < names.index("Zelda")


# ---------------------------------------------------------------------------
# find_contact
# ---------------------------------------------------------------------------

async def test_find_contact_by_name(ctx):
  await add_contact(ctx, name="Charlie Brown", email="charlie@peanuts.com")
  result = await find_contact(ctx, query="Charlie")
  assert result["status"] == "ok"
  names = [c["name"] for c in result["contacts"]]
  assert "Charlie Brown" in names


async def test_find_contact_by_email(ctx):
  await add_contact(ctx, name="Diana Prince", email="diana@themyscira.com")
  result = await find_contact(ctx, query="themyscira")
  assert result["status"] == "ok"
  assert len(result["contacts"]) >= 1


async def test_find_contact_no_match(ctx):
  result = await find_contact(ctx, query="xyznoone123")
  assert result["status"] == "ok"
  assert result["contacts"] == []


async def test_find_contact_case_insensitive(ctx):
  await add_contact(ctx, name="Eric Idle", email="eric@montypython.com")
  result = await find_contact(ctx, query="eric idle")
  names = [c["name"] for c in result["contacts"]]
  assert "Eric Idle" in names


# ---------------------------------------------------------------------------
# update_contact
# ---------------------------------------------------------------------------

async def test_update_contact_name(ctx):
  item = await add_contact(ctx, name="Old Name")
  cid = item["contact"]["id"]
  result = await update_contact(ctx, contact_id=cid, name="New Name")
  assert result["status"] == "ok"
  assert result["contact"]["name"] == "New Name"


async def test_update_contact_email(ctx):
  item = await add_contact(ctx, name="Email Update", email="old@example.com")
  cid = item["contact"]["id"]
  result = await update_contact(ctx, contact_id=cid, email="new@example.com")
  assert result["contact"]["email"] == "new@example.com"


async def test_update_contact_not_found(ctx):
  result = await update_contact(ctx, contact_id=999999, name="Ghost")
  assert result["status"] == "error"
  assert "not found" in result["message"].lower()


async def test_update_contact_partial_fields(ctx):
  """Un-supplied fields must retain their original values."""
  item = await add_contact(ctx, name="Partial", email="p@example.com", phone="123")
  cid = item["contact"]["id"]
  result = await update_contact(ctx, contact_id=cid, phone="456")
  assert result["contact"]["email"] == "p@example.com"
  assert result["contact"]["phone"] == "456"


# ---------------------------------------------------------------------------
# delete_contact
# ---------------------------------------------------------------------------

async def test_delete_contact_removes_it(ctx, engine_ctx):
  from tests.conftest import FakeRunContext
  from subconscious.tools import EngineContext

  # Use an isolated workspace to avoid other tests' contacts appearing in list
  ctx_iso = FakeRunContext(deps=EngineContext(db=engine_ctx.db, workspace_id=300, thread_id=1))
  item = await add_contact(ctx_iso, name="Delete Target")
  cid = item["contact"]["id"]
  del_result = await delete_contact(ctx_iso, contact_id=cid)
  assert del_result["status"] == "ok"

  all_contacts = await list_contacts(ctx_iso)
  ids = [c["id"] for c in all_contacts["contacts"]]
  assert cid not in ids


async def test_delete_contact_not_found(ctx):
  result = await delete_contact(ctx, contact_id=999999)
  assert result["status"] == "error"


# ---------------------------------------------------------------------------
# Workspace isolation
# ---------------------------------------------------------------------------

async def test_contacts_workspace_isolated(ctx, engine_ctx):
  from tests.conftest import FakeRunContext
  from subconscious.tools import EngineContext

  ctx2 = FakeRunContext(deps=EngineContext(
    db=engine_ctx.db, workspace_id=200, thread_id=1
  ))
  await add_contact(ctx, name="WS1 Contact")
  result2 = await list_contacts(ctx2)
  names = [c["name"] for c in result2["contacts"]]
  assert "WS1 Contact" not in names
