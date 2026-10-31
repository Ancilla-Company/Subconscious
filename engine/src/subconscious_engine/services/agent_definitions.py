"""Agent definitions: reusable assistant profiles, per workspace or account-wide.

An agent is a special kind of thread configuration: instructions, a default model and the
same tool/approval settings a workspace or thread carries. ``tools_config`` and
``approval_config`` hold the existing JSON formats; NULL inherits the workspace's.
"""

from __future__ import annotations

import json
from uuid import uuid4

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.extra_schemas import AgentDto, UpsertAgentRequest
from subconscious_engine.storage.models import AgentRecord, Workspace, utc_now

MAX_NAME = 80
MAX_DESCRIPTION = 500
MAX_INSTRUCTIONS = 20000


def _json_object(raw: str | None, label: str) -> str | None:
    """``raw`` unchanged when it is a JSON object; None for an empty value."""
    if raw is None or not raw.strip():
        return None
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as problem:
        raise ValueError(f"{label} must be a JSON object.") from problem
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object.")
    return raw


class AgentDefinitionService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list_all(self, workspace_uuid: str | None = None) -> list[AgentDto]:
        """Every agent, or with ``workspace_uuid`` the account-wide ones plus that workspace's."""
        query = (select(AgentRecord, Workspace.uuid)
                 .outerjoin(Workspace, AgentRecord.workspace_id == Workspace.id)
                 .where(or_(AgentRecord.workspace_id.is_(None), Workspace.deleted_at.is_(None))))
        if workspace_uuid:
            query = query.where(or_(AgentRecord.workspace_id.is_(None), Workspace.uuid == workspace_uuid))
        rows = (await self.session.execute(query.order_by(func.lower(AgentRecord.name), AgentRecord.id))).all()
        return [self._dto(record, owner) for record, owner in rows]

    async def get(self, uuid: str) -> AgentDto | None:
        found = await self._row(uuid)
        return None if found is None else self._dto(*found)

    async def create(self, request: UpsertAgentRequest) -> AgentDto:
        now = utc_now()
        row = AgentRecord(uuid=str(uuid4()), created_at=now, updated_at=now, enabled=True, name="")
        owner = await self._apply(row, request, creating=True)
        self.session.add(row)
        await self.session.commit()
        return self._dto(row, owner)

    async def update(self, uuid: str, request: UpsertAgentRequest) -> AgentDto | None:
        found = await self._row(uuid)
        if found is None:
            return None
        row, owner = found
        owner = await self._apply(row, request, creating=False, current_owner=owner)
        row.updated_at = utc_now()
        await self.session.commit()
        return self._dto(row, owner)

    async def delete(self, uuid: str) -> bool:
        found = await self._row(uuid)
        if found is None:
            return False
        await self.session.delete(found[0])
        await self.session.commit()
        return True

    async def _row(self, uuid: str) -> tuple[AgentRecord, str | None] | None:
        result = (await self.session.execute(
            select(AgentRecord, Workspace.uuid)
            .outerjoin(Workspace, AgentRecord.workspace_id == Workspace.id)
            .where(AgentRecord.uuid == uuid,
                   or_(AgentRecord.workspace_id.is_(None), Workspace.deleted_at.is_(None))))).first()
        return None if result is None else (result[0], result[1])

    async def _apply(self, row: AgentRecord, request: UpsertAgentRequest, *, creating: bool,
                     current_owner: str | None = None) -> str | None:
        """Copy the fields ``request`` carries onto ``row``; returns the owning workspace uuid."""
        sent = request.model_fields_set
        if creating or "name" in sent:
            name = " ".join((request.name or "").split())
            if not name:
                raise ValueError("An agent needs a name.")
            if len(name) > MAX_NAME:
                raise ValueError(f"Agent names are limited to {MAX_NAME} characters.")
            row.name = name
        if creating or "description" in sent:
            description = (request.description or "").strip() or None
            if description is not None and len(description) > MAX_DESCRIPTION:
                raise ValueError(f"Agent descriptions are limited to {MAX_DESCRIPTION} characters.")
            row.description = description
        if creating or "instructions" in sent:
            instructions = (request.instructions or "").strip() or None
            if instructions is not None and len(instructions) > MAX_INSTRUCTIONS:
                raise ValueError(f"Agent instructions are limited to {MAX_INSTRUCTIONS} characters.")
            row.instructions = instructions
        if creating or "default_model_id" in sent:
            row.default_model_id = (request.default_model_id or "").strip() or None
        if creating or "tools_config" in sent:
            row.tools_config = _json_object(request.tools_config, "Tools configuration")
        if creating or "approval_config" in sent:
            row.approval_config = _json_object(request.approval_config, "Approval configuration")
        if "enabled" in sent and request.enabled is not None:
            row.enabled = request.enabled
        owner = current_owner
        if creating or "workspace_uuid" in sent:
            owner = (request.workspace_uuid or "").strip() or None
            if owner is None:
                row.workspace_id = None
            else:
                workspace = await self.session.scalar(select(Workspace).where(
                    Workspace.uuid == owner, Workspace.deleted_at.is_(None)))
                if workspace is None:
                    raise ValueError("Workspace not found.")
                row.workspace_id = workspace.id
        await self._require_unique_name(row)
        return owner

    async def _require_unique_name(self, row: AgentRecord) -> None:
        """Names are unique (ignoring case) within one scope: a workspace, or account-wide."""
        scope = AgentRecord.workspace_id.is_(None) if row.workspace_id is None \
            else AgentRecord.workspace_id == row.workspace_id
        taken = (await self.session.scalars(select(AgentRecord.name).where(
            scope, AgentRecord.uuid != row.uuid))).all()
        if row.name.casefold() in {name.casefold() for name in taken}:
            raise ValueError("An agent with this name already exists here.")

    @staticmethod
    def _dto(row: AgentRecord, workspace_uuid: str | None) -> AgentDto:
        return AgentDto(
            uuid=row.uuid, name=row.name, description=row.description, instructions=row.instructions,
            default_model_id=row.default_model_id, tools_config=row.tools_config,
            approval_config=row.approval_config, workspace_uuid=workspace_uuid, enabled=row.enabled,
            created_at=row.created_at, updated_at=row.updated_at)
