"""Skills: reusable instruction sets the model reads on demand via ``read_skill``.

A skill is either a folder (or single ``.md`` file) containing ``SKILL.md`` with optional
YAML-style frontmatter (``name:``/``description:``), or plain instructions stored in the
database. Only a short index (name + description) is placed in the system prompt; the full
body is fetched by the ``read_skill`` tool, so unused skills cost almost no context.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import uuid4

from pydantic_ai import Tool
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.extra_schemas import SkillDto, UpsertSkillRequest
from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.services.builtin_skills import (
    BUILTIN_UUID_PREFIX,
    MANAGING_TOOLS_DESCRIPTION,
    MANAGING_TOOLS_INSTRUCTIONS,
    MANAGING_TOOLS_NAME,
)
from subconscious_engine.storage.models import SkillRecord, utc_now

_LOG = logging.getLogger(__name__)
_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MAX_NAME = 64
MAX_INSTRUCTIONS = 20000
MAX_SKILL_BODY = 40000
MAX_INDEX_DESCRIPTION = 200
MAX_INDEX_CHARS = 4000
MAX_SIBLINGS = 100
NONE_INDEX = "(none)"
SKILL_FILE = "SKILL.md"
_SOURCE_TYPES = frozenset({"folder", "text"})


def split_frontmatter(text: str) -> tuple[dict[str, str], str]:
    """Split ``---`` delimited frontmatter from the body.

    Only flat ``key: value`` pairs are understood (plain, quoted, and ``>``/``|`` block
    scalars), which covers SKILL.md conventions without a YAML dependency.
    """
    text = text.removeprefix("\ufeff")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, text
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        return {}, text
    meta: dict[str, str] = {}
    index = 1
    while index < end:
        line = lines[index]
        match = re.match(r"^([A-Za-z0-9_-]+)\s*:\s*(.*)$", line)
        index += 1
        if match is None:
            continue
        key, value = match.group(1).casefold(), match.group(2).strip()
        if value in {">", "|", ">-", "|-", ">+", "|+"}:
            block: list[str] = []
            while index < end and (not lines[index].strip() or lines[index][:1] in {" ", "\t"}):
                block.append(lines[index].strip())
                index += 1
            value = (" " if value.startswith(">") else "\n").join(part for part in block if part)
        else:
            continuation: list[str] = []
            while index < end and lines[index][:1] in {" ", "\t"} and lines[index].strip():
                continuation.append(lines[index].strip())
                index += 1
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
                value = value[1:-1]
            if continuation:
                value = " ".join([value, *continuation]).strip()
        meta[key] = value
    return meta, "\n".join(lines[end + 1:]).lstrip("\r\n")


def _skill_file(source: str | None) -> tuple[Path | None, str | None]:
    """Resolve the SKILL.md for a folder source; returns ``(path, error)``."""
    if not source or not source.strip():
        return None, "No folder is set for this skill."
    path = Path(source.strip()).expanduser()
    if path.is_dir():
        candidate = path / SKILL_FILE
        if candidate.is_file():
            return candidate, None
        return None, f"The folder does not contain {SKILL_FILE}."
    if path.is_file():
        if path.suffix.casefold() == ".md":
            return path, None
        return None, "The skill file must be a Markdown (.md) file."
    return None, "The skill folder was not found."


@dataclass(frozen=True, slots=True)
class SkillInfo:
    uuid: str
    name: str
    alias: str | None
    description: str | None
    source_type: str
    source: str | None
    instructions: str | None
    enabled: bool
    valid: bool
    error: str | None


def builtin_skills() -> list[SkillInfo]:
    """Skills defined in code (read-only; never stored, listed over REST or deletable)."""
    return [SkillInfo(f"{BUILTIN_UUID_PREFIX}{MANAGING_TOOLS_NAME}", MANAGING_TOOLS_NAME, None,
                      MANAGING_TOOLS_DESCRIPTION, "text", None, MANAGING_TOOLS_INSTRUCTIONS,
                      True, True, None)]


def _info(row: SkillRecord) -> SkillInfo:
    if row.source_type == "text":
        valid, error = bool((row.instructions or "").strip()), None
        if not valid:
            error = "This skill has no instructions."
    else:
        path, error = _skill_file(row.source)
        valid = path is not None
    return SkillInfo(row.uuid, row.name, row.alias, row.description, row.source_type, row.source,
                     row.instructions, row.enabled, valid, error)


class SkillService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list(self) -> list[SkillDto]:
        return [self._dto(row) for row in await self._rows()]

    async def snapshots(self) -> list[SkillInfo]:
        """All skills with validity computed now; never raises because a folder vanished.

        Built-in skills are appended unless a user skill uses the same name.
        """
        infos = [_info(row) for row in await self._rows()]
        taken = {info.name.casefold() for info in infos}
        return infos + [skill for skill in builtin_skills() if skill.name.casefold() not in taken]

    async def get(self, uuid: str) -> SkillDto | None:
        row = await self._row(uuid)
        return None if row is None else self._dto(row)

    async def create(self, request: UpsertSkillRequest) -> SkillDto:
        now = utc_now()
        row = SkillRecord(uuid=str(uuid4()), created_at=now, updated_at=now)
        await self._apply(row, request)
        self.session.add(row)
        await self.session.commit()
        return self._dto(row)

    async def update(self, uuid: str, request: UpsertSkillRequest) -> SkillDto | None:
        row = await self._row(uuid)
        if row is None:
            return None
        await self._apply(row, request)
        row.updated_at = utc_now()
        await self.session.commit()
        return self._dto(row)

    async def delete(self, uuid: str) -> bool:
        row = await self._row(uuid)
        if row is None:
            return False
        await self.session.delete(row)
        await self.session.commit()
        return True

    async def _rows(self) -> list[SkillRecord]:
        return list((await self.session.scalars(select(SkillRecord).order_by(SkillRecord.name))).all())

    async def _row(self, uuid: str) -> SkillRecord | None:
        return await self.session.scalar(select(SkillRecord).where(SkillRecord.uuid == uuid))

    async def _apply(self, row: SkillRecord, request: UpsertSkillRequest) -> None:
        name = (request.name or "").strip()
        if not name or len(name) > MAX_NAME or not _NAME.fullmatch(name):
            raise ValueError("Skill name must be 1-64 characters: letters, digits, '.', '_' or '-', "
                             "starting with a letter or digit.")
        source_type = (request.source_type or "folder").strip().casefold()
        if source_type not in _SOURCE_TYPES:
            raise ValueError("Skill source type must be folder or text.")
        taken = {other.casefold() for other in (await self.session.scalars(
            select(SkillRecord.name).where(SkillRecord.uuid != (row.uuid or "")))).all()}
        if name.casefold() in taken:
            raise ValueError("A skill with this name already exists.")
        description = (request.description or "").strip() or None
        source: str | None = None
        instructions: str | None = None
        if source_type == "folder":
            source = (request.source or "").strip()
            path, error = _skill_file(source)
            if path is None:
                raise ValueError(error or "The skill folder was not found.")
            if description is None:
                description = self._frontmatter_description(path)
        else:
            instructions = (request.instructions or "").strip()
            if not instructions:
                raise ValueError("Skill instructions cannot be empty.")
            if len(instructions) > MAX_INSTRUCTIONS:
                raise ValueError(f"Skill instructions are limited to {MAX_INSTRUCTIONS} characters.")
        row.name = name
        row.alias = (request.alias or "").strip() or None
        row.description = description
        row.source_type = source_type
        row.source = source
        row.instructions = instructions
        row.enabled = bool(request.enabled)

    @staticmethod
    def _frontmatter_description(path: Path) -> str | None:
        try:
            meta, _ = split_frontmatter(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            _LOG.warning("services.skills._frontmatter_description: could not read %s", path, exc_info=True)
            return None
        return (meta.get("description") or "").strip() or None

    @staticmethod
    def _dto(row: SkillRecord) -> SkillDto:
        info = _info(row)
        return SkillDto(uuid=row.uuid, name=row.name, alias=row.alias, description=row.description,
            source_type=row.source_type, source=row.source,
            instructions=row.instructions if row.source_type == "text" else None,
            enabled=row.enabled, valid=info.valid, error=info.error,
            created_at=row.created_at, updated_at=row.updated_at)


def resolve_skill_filter(*raw_configs: str | None) -> list[str] | None:
    """First config (thread, then workspace) that is a non-empty JSON list of strings, else None."""
    for raw in raw_configs:
        if not isinstance(raw, str) or not raw.strip():
            continue
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            _LOG.warning("services.skills.resolve_skill_filter: invalid skills_config ignored", exc_info=True)
            continue
        if isinstance(value, list) and value and all(isinstance(item, str) for item in value):
            return [item.strip() for item in value if item.strip()] or None
    return None


def select_skills(skills: list[SkillInfo], *raw_configs: str | None) -> list[SkillInfo]:
    """Enabled, valid skills, restricted to the names/uuids a skills_config lists (if any)."""
    usable = [skill for skill in skills if skill.enabled and skill.valid]
    wanted = resolve_skill_filter(*raw_configs)
    if wanted is None:
        return usable
    folded = {item.casefold() for item in wanted}
    # Built-in skills are never filtered out: the tool-management tools depend on them.
    return [skill for skill in usable if skill.name.casefold() in folded or skill.uuid.casefold() in folded
            or skill.uuid.startswith(BUILTIN_UUID_PREFIX)]


def _summary(skill: SkillInfo) -> str:
    text = (skill.description or "").strip()
    if not text and skill.source_type == "text":
        text = next((line.strip() for line in (skill.instructions or "").splitlines() if line.strip()), "")
    text = " ".join(text.split())
    return text if len(text) <= MAX_INDEX_DESCRIPTION else text[:MAX_INDEX_DESCRIPTION - 1] + "…"


def build_skills_index(skills: list[SkillInfo]) -> str:
    """One line per skill for the system prompt; always a non-empty string."""
    if not skills:
        return NONE_INDEX
    lines: list[str] = []
    used = 0
    for position, skill in enumerate(skills):
        summary = _summary(skill)
        line = f"- {skill.name}: {summary}" if summary else f"- {skill.name}"
        if used + len(line) + 1 > MAX_INDEX_CHARS:
            lines.append(f"...and {len(skills) - position} more")
            break
        lines.append(line)
        used += len(line) + 1
    return "\n".join(lines)


def _sibling_files(folder: Path, skill_file: Path) -> list[str]:
    found: list[str] = []
    try:
        for item in sorted(folder.rglob("*")):
            if item.is_file() and item != skill_file:
                found.append(str(item.relative_to(folder)).replace("\\", "/"))
            if len(found) >= MAX_SIBLINGS:
                break
    except OSError:
        _LOG.warning("services.skills._sibling_files: could not list %s", folder, exc_info=True)
    return found


def read_skill_body(skill: SkillInfo) -> str:
    """Full skill instructions; folder skills are read from disk at call time."""
    if skill.source_type == "text":
        return (skill.instructions or "").strip()
    path, error = _skill_file(skill.source)
    if path is None:
        raise ValueError(f"Skill '{skill.name}' is unavailable: {error}")
    try:
        _, body = split_frontmatter(path.read_text(encoding="utf-8", errors="replace"))
    except OSError as problem:
        _LOG.warning("services.skills.read_skill_body: could not read %s", path, exc_info=True)
        raise ValueError(f"Skill '{skill.name}' could not be read: {problem}") from problem
    truncated = len(body) > MAX_SKILL_BODY
    parts = [body[:MAX_SKILL_BODY].rstrip()]
    if truncated:
        parts.append(f"[Truncated at {MAX_SKILL_BODY} characters.]")
    folder = path.parent
    siblings = _sibling_files(folder, path)
    parts.append(f"Skill folder: {folder}")
    if siblings:
        parts.append("Other files in this skill folder (read them with the file tools):\n"
                     + "\n".join(f"- {name}" for name in siblings))
    return "\n\n".join(part for part in parts if part)


def read_skill_tool(skills: list[SkillInfo], approval: ApprovalConfig) -> Tool[Any] | None:
    """The per-turn ``read_skill`` tool; None when there is nothing to read."""
    if not skills:
        return None
    by_key: dict[str, SkillInfo] = {}
    for skill in skills:
        by_key.setdefault(skill.name.casefold(), skill)
    for skill in skills:
        if skill.alias:
            by_key.setdefault(skill.alias.casefold(), skill)
        by_key.setdefault(skill.uuid.casefold(), skill)
    known = ", ".join(skill.name for skill in skills)

    def read_skill(name: str) -> str:
        """Read the full instructions of a skill listed under 'Active skills'."""
        skill = by_key.get(name.strip().casefold())
        if skill is None:
            raise ValueError(f"Unknown skill '{name}'. Known skills: {known}")
        return read_skill_body(skill)

    return Tool(
        read_skill, name="read_skill",
        description=("Read the full instructions of a skill. Call this when a skill listed under "
                     "'Active skills' is relevant to the user's request, then follow it."),
        requires_approval=approval.requires("read_skill"))
