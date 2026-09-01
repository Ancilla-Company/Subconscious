"""Workspace persistence service."""

from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.schemas import CreateWorkspaceRequest, WorkspaceDto
from subconscious_engine.storage.models import Network, Workspace, utc_now


class WorkspaceService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list(self) -> list[WorkspaceDto]:
        rows = (await self.session.scalars(select(Workspace).order_by(Workspace.name))).all()
        return [self._dto(row) for row in rows]

    async def get(self, uuid: str) -> Workspace | None:
        return await self.session.scalar(select(Workspace).where(Workspace.uuid == uuid))

    async def create(self, request: CreateWorkspaceRequest) -> WorkspaceDto:
        network = await self.session.scalar(select(Network))
        if network is None:
            network = Network(uuid=str(uuid4()), name="default", description="Default network")
            self.session.add(network)
            await self.session.flush()
        now = utc_now()
        values = request.model_dump(by_alias=False)
        row = Workspace(uuid=str(uuid4()), network_id=network.id, created_at=now, updated_at=now, **values)
        self.session.add(row)
        await self.session.commit()
        return self._dto(row)

    async def update(self, row: Workspace, request: CreateWorkspaceRequest) -> WorkspaceDto:
        for key, value in request.model_dump(by_alias=False).items():
            setattr(row, key, value)
        row.updated_at = utc_now()
        await self.session.commit()
        return self._dto(row)

    async def delete(self, row: Workspace) -> None:
        await self.session.delete(row)
        await self.session.commit()

    @staticmethod
    def _dto(row: Workspace) -> WorkspaceDto:
        return WorkspaceDto.model_validate(row, from_attributes=True)
