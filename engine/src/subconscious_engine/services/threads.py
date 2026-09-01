"""Conversation thread persistence service."""

from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from subconscious_engine.api.schemas import CreateThreadRequest, ThreadDto, UpdateThreadRequest
from subconscious_engine.storage.models import ConversationThread, Workspace, utc_now


class ThreadService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list(self, workspace_uuid: str) -> list[ThreadDto]:
        workspace = await self.session.scalar(select(Workspace).where(Workspace.uuid == workspace_uuid))
        if workspace is None:
            return []
        query = select(ConversationThread).where(ConversationThread.workspace_id == workspace.id).order_by(ConversationThread.updated_at.desc())
        rows = (await self.session.scalars(query)).all()
        return [self._dto(row, workspace) for row in rows]

    async def get(self, uuid: str) -> ConversationThread | None:
        query = select(ConversationThread).options(selectinload(ConversationThread.workspace)).where(ConversationThread.uuid == uuid)
        return await self.session.scalar(query)

    async def create(self, request: CreateThreadRequest) -> ThreadDto | None:
        workspace = await self.session.scalar(select(Workspace).where(Workspace.uuid == request.workspace_uuid))
        if workspace is None:
            return None
        values = request.model_dump(exclude={"workspace_uuid"}, by_alias=False)
        now = utc_now()
        row = ConversationThread(uuid=str(uuid4()), workspace_id=workspace.id, created_at=now, updated_at=now, **values)
        self.session.add(row)
        await self.session.commit()
        return self._dto(row, workspace)

    async def update(self, row: ConversationThread, request: UpdateThreadRequest) -> ThreadDto:
        for key, value in request.model_dump(exclude_unset=True, by_alias=False).items():
            setattr(row, key, value)
        row.updated_at = utc_now()
        await self.session.commit()
        return self._dto(row, row.workspace)

    async def delete(self, row: ConversationThread) -> None:
        await self.session.delete(row)
        await self.session.commit()

    @staticmethod
    def _dto(row: ConversationThread, workspace: Workspace) -> ThreadDto:
        return ThreadDto(id=row.id, uuid=row.uuid, workspace_uuid=workspace.uuid, title=row.title,
                         description=row.description, default_model_id=row.default_model_id,
                         tools_config=row.tools_config,
                         created_at=row.created_at, updated_at=row.updated_at)
