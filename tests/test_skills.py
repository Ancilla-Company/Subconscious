"""Skills: CRUD API and validation, SKILL.md parsing, the prompt index, and read_skill."""

import json
import shutil

import pytest

from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.services.skills import (
    MAX_INDEX_CHARS,
    SkillInfo,
    build_skills_index,
    read_skill_tool,
    resolve_skill_filter,
    select_skills,
    split_frontmatter,
)

from test_api import api_client, auth, run

SKILL_MD = """---
name: pdf-tools
description: >
  Extract text from PDFs
  and merge them.
license: MIT
---
# PDF tools

Use pdftotext.
"""


def make_skill_folder(root, name="pdf", text=SKILL_MD):
    folder = root / name
    folder.mkdir()
    (folder / "SKILL.md").write_text(text, encoding="utf-8")
    (folder / "scripts").mkdir()
    (folder / "scripts" / "run.py").write_text("print(1)", encoding="utf-8")
    (folder / "REFERENCE.md").write_text("ref", encoding="utf-8")
    return folder


def info(name, description=None, *, source_type="text", instructions="body", enabled=True, valid=True,
         source=None, uuid=None):
    return SkillInfo(uuid or f"uuid-{name}", name, None, description, source_type, source,
                     instructions, enabled, valid, None)


# --- API ---------------------------------------------------------------------------------------


def test_skill_crud_and_validation(tmp_path):
    folder = make_skill_folder(tmp_path)

    async def scenario():
        async with api_client(tmp_path) as (client, _):
            async def post(body):
                return await client.post("/api/v1/skills", headers=auth(), json=body)

            created = await post({"name": "Deploy", "sourceType": "text", "instructions": "Do it.",
                                  "description": "Ship it"})
            assert created.status_code == 201, created.text
            skill = created.json()
            assert created.headers["location"] == f"/api/v1/skills/{skill['uuid']}"
            assert skill["name"] == "Deploy" and skill["sourceType"] == "text" and skill["source"] is None
            assert skill["instructions"] == "Do it." and skill["enabled"] is True and skill["valid"] is True
            assert skill["error"] is None and "createdAt" in skill and "updatedAt" in skill

            duplicate = await post({"name": "deploy", "sourceType": "text", "instructions": "x"})
            assert duplicate.status_code == 400
            assert duplicate.json() == {"error": "A skill with this name already exists."}

            for body, fragment in (
                ({"name": "", "sourceType": "text", "instructions": "x"}, "name"),
                ({"name": "-bad", "sourceType": "text", "instructions": "x"}, "name"),
                ({"name": "a" * 65, "sourceType": "text", "instructions": "x"}, "name"),
                ({"name": "has space", "sourceType": "text", "instructions": "x"}, "name"),
                ({"name": "t1", "sourceType": "text", "instructions": "   "}, "instructions"),
                ({"name": "t2", "sourceType": "text"}, "instructions"),
                ({"name": "t3", "sourceType": "text", "instructions": "x" * 20001}, "20000"),
                ({"name": "f1", "sourceType": "folder", "source": str(tmp_path / "nope")}, "not found"),
                ({"name": "f2", "source": None}, "folder"),
                ({"name": "f3", "sourceType": "folder", "source": str(tmp_path)}, "SKILL.md"),
                ({"name": "f4", "sourceType": "weird", "instructions": "x"}, "type"),
            ):
                bad = await post(body)
                assert bad.status_code == 400 and fragment in bad.json()["error"], (body, bad.text)
            assert (await client.post("/api/v1/skills", headers=auth(), content=b"{")).status_code == 400

            assert [s["name"] for s in (await client.get("/api/v1/skills", headers=auth())).json()] == ["Deploy"]
            url = f"/api/v1/skills/{skill['uuid']}"
            assert (await client.get(url, headers=auth())).json()["name"] == "Deploy"
            # Renaming to its own name (any case) is fine; to another skill's name is not.
            updated = await client.put(url, headers=auth(), json={
                "name": "deploy", "sourceType": "text", "instructions": "New.", "enabled": False})
            assert updated.status_code == 200 and updated.json()["enabled"] is False
            assert updated.json()["instructions"] == "New."
            other = (await post({"name": "other", "sourceType": "text", "instructions": "x"})).json()
            clash = await client.put(f"/api/v1/skills/{other['uuid']}", headers=auth(), json={
                "name": "DEPLOY", "sourceType": "text", "instructions": "x"})
            assert clash.status_code == 400
            assert (await client.put("/api/v1/skills/missing", headers=auth(), json={
                "name": "z", "sourceType": "text", "instructions": "x"})).status_code == 404
            assert (await client.get("/api/v1/skills/missing", headers=auth())).status_code == 404
            assert (await client.delete(url, headers=auth())).status_code == 204
            assert (await client.delete(url, headers=auth())).status_code == 404

            # A folder skill: frontmatter fills a blank description; an explicit one wins.
            filled = (await post({"name": "pdf", "sourceType": "folder", "source": str(folder)})).json()
            assert filled["description"] == "Extract text from PDFs and merge them."
            assert filled["valid"] is True and filled["instructions"] is None and filled["source"] == str(folder)
            explicit = await post({"name": "pdf2", "source": str(folder / "SKILL.md"),
                                   "description": "Mine"})
            assert explicit.status_code == 201 and explicit.json()["description"] == "Mine"

            # The folder vanishes: listing still works and flags the skill.
            shutil.rmtree(folder)
            listed = (await client.get("/api/v1/skills", headers=auth())).json()
            by_name = {s["name"]: s for s in listed}
            assert by_name["pdf"]["valid"] is False and by_name["pdf"]["error"]
            assert by_name["pdf2"]["valid"] is False and by_name["other"]["valid"] is True
            assert (await client.get(f"/api/v1/skills/{filled['uuid']}", headers=auth())).json()["valid"] is False

    run(scenario())


# --- parsing, index, selection -------------------------------------------------------------


def test_frontmatter_parsing_handles_plain_quoted_block_and_missing_values():
    meta, body = split_frontmatter(SKILL_MD)
    assert meta["description"] == "Extract text from PDFs and merge them." and meta["name"] == "pdf-tools"
    assert body.startswith("# PDF tools")
    meta, body = split_frontmatter('---\ndescription: "Quoted: yes"\nother: 1\n---\nText')
    assert meta["description"] == "Quoted: yes" and body == "Text"
    meta, _ = split_frontmatter("---\ndescription: |\n  line one\n  line two\n---\nx")
    assert meta["description"] == "line one\nline two"
    assert split_frontmatter("No frontmatter") == ({}, "No frontmatter")
    assert split_frontmatter("---\nunterminated") == ({}, "---\nunterminated")


def test_index_lists_name_and_description_with_caps_and_a_non_empty_fallback():
    assert build_skills_index([]) == "(none)"
    text_skill = info("notes", None, instructions="\n\nFirst line here\nsecond")
    long_skill = info("long", "d" * 500)
    index = build_skills_index([text_skill, long_skill, info("bare", source_type="folder", instructions=None)])
    lines = index.splitlines()
    assert lines[0] == "- notes: First line here"
    assert lines[1].startswith("- long: ddd") and len(lines[1]) <= len("- long: ") + 200
    assert lines[2] == "- bare"
    many = [info(f"skill-{i:04d}", "x" * 150) for i in range(100)]
    capped = build_skills_index(many)
    assert len(capped) <= MAX_INDEX_CHARS + 40
    assert capped.splitlines()[-1].startswith("...and ") and capped.splitlines()[-1].endswith(" more")
    listed = capped.count("\n")
    assert f"...and {100 - listed} more" in capped


def test_skills_config_restricts_only_when_it_is_a_non_empty_list_of_strings():
    a, b = info("alpha"), info("beta")
    off, broken = info("off", enabled=False), info("broken", valid=False)
    everything = [a, b, off, broken]
    assert select_skills(everything) == [a, b]
    for raw in (None, "", "[]", "not json", '{"x": 1}', "[1, 2]", '"alpha"'):
        assert select_skills(everything, raw) == [a, b], raw
    assert select_skills(everything, '["BETA"]') == [b]
    assert select_skills(everything, json.dumps([a.uuid])) == [a]
    assert select_skills(everything, '["off", "broken"]') == []  # still never offers disabled/invalid
    assert select_skills(everything, '["alpha"]', '["beta"]') == [a]  # the thread's list wins
    assert select_skills(everything, "[]", '["beta"]') == [b]  # an empty thread list defers to the workspace
    assert resolve_skill_filter(None, "[]") is None


# --- read_skill ----------------------------------------------------------------------------------


def test_read_skill_returns_text_or_disk_content_and_lists_unknown_names(tmp_path):
    folder = make_skill_folder(tmp_path)
    text_skill = info("notes", instructions="  Remember this.  ")
    folder_skill = info("pdf", source_type="folder", instructions=None, source=str(folder))
    assert read_skill_tool([], ApprovalConfig()) is None
    tool = read_skill_tool([text_skill, folder_skill], ApprovalConfig())
    assert tool.name == "read_skill" and "Active skills" in tool.description
    assert tool.requires_approval is True and read_skill_tool([text_skill], ApprovalConfig(read=False)).requires_approval is False
    assert tool.function(name="notes") == "Remember this."
    body = tool.function(name="PDF")
    assert body.startswith("# PDF tools") and "description:" not in body and "name: pdf-tools" not in body
    assert f"Skill folder: {folder}" in body
    assert "REFERENCE.md" in body and "scripts/run.py" in body and "- SKILL.md" not in body
    (folder / "SKILL.md").write_text("---\nname: x\n---\nChanged on disk", encoding="utf-8")
    assert tool.function(name="pdf").startswith("Changed on disk")  # read at call time
    with pytest.raises(ValueError, match="Unknown skill 'nope'.*notes, pdf"):
        tool.function(name="nope")
    (folder / "SKILL.md").write_text("x" * 50000, encoding="utf-8")
    long = tool.function(name="pdf")
    assert "Truncated at 40000" in long and long.startswith("x" * 40000 + "\n")
    shutil.rmtree(folder)
    with pytest.raises(ValueError, match="unavailable"):
        tool.function(name="pdf")
