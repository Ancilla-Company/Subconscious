"""
Unit tests for subconscious.tools.notes
"""

import pytest
from subconscious.desktop_tools.notes import save_note, list_notes, get_note, delete_note


# ---------------------------------------------------------------------------
# save_note
# ---------------------------------------------------------------------------

async def test_save_note_creates_new(ctx):
  result = await save_note(ctx, title="My Note", content="Hello notes world")
  assert result["action"] == "created"
  assert "id" in result


async def test_save_note_updates_existing(ctx):
  await save_note(ctx, title="Upsert Note", content="v1")
  result = await save_note(ctx, title="Upsert Note", content="v2")
  assert result["action"] == "updated"


async def test_save_note_with_tags(ctx):
  result = await save_note(ctx, title="Tagged Note", content="body", tags="work, urgent")
  assert result["action"] in ("created", "updated")


# ---------------------------------------------------------------------------
# list_notes
# ---------------------------------------------------------------------------

async def test_list_notes_finds_saved_note(ctx):
  await save_note(ctx, title="Listable Note", content="content here")
  result = await list_notes(ctx)
  titles = [n.get("title") for n in result]
  assert "Listable Note" in titles


async def test_list_notes_filter_by_tag(ctx):
  await save_note(ctx, title="Tag Filter Note", content="x", tags="cooking")
  result = await list_notes(ctx, tag="cooking")
  titles = [n.get("title") for n in result]
  assert "Tag Filter Note" in titles


async def test_list_notes_filter_no_match(ctx):
  result = await list_notes(ctx, tag="zzznotexist")
  # Returns empty list or message dict
  assert isinstance(result, list)
  if result and "message" not in result[0]:
    assert len(result) == 0


async def test_list_notes_preview_truncated(ctx):
  long_content = "A" * 200
  await save_note(ctx, title="Long Note Preview", content=long_content)
  result = await list_notes(ctx)
  note = next((n for n in result if n.get("title") == "Long Note Preview"), None)
  assert note is not None
  assert len(note["preview"]) <= 125  # 120 chars + ellipsis


# ---------------------------------------------------------------------------
# get_note
# ---------------------------------------------------------------------------

async def test_get_note_returns_full_content(ctx):
  created = await save_note(ctx, title="Full Content Note", content="full body here")
  result = await get_note(ctx, note_id=created["id"])
  assert isinstance(result, dict)
  assert "full body here" in result.get("content", "")


async def test_get_note_not_found(ctx):
  result = await get_note(ctx, note_id=999999)
  assert "error" in result


# ---------------------------------------------------------------------------
# delete_note
# ---------------------------------------------------------------------------

async def test_delete_note_removes_it(ctx):
  created = await save_note(ctx, title="Delete Me Note", content="bye")
  del_result = await delete_note(ctx, note_id=created["id"])
  assert "deleted" in del_result.lower() or "ok" in del_result.lower()

  result = await get_note(ctx, note_id=created["id"])
  assert "error" in result


async def test_delete_note_not_found(ctx):
  result = await delete_note(ctx, note_id=999999)
  assert "not found" in result.lower()
