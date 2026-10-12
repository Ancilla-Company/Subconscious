"""Client-scoped app-state settings service."""

from __future__ import annotations

import builtins

from sqlalchemy import delete as sql_delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.extra_schemas import AppStateSettingDto
from subconscious_engine.storage.models import AppState


class SettingsService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list(self, key: str | None, tag: str | None, client: str | None) -> list[AppStateSettingDto]:
        query = select(AppState)
        if key is not None:
            query = query.where(AppState.key == key)
        if tag is not None:
            query = query.where(AppState.tag == tag)
        if client is not None:
            query = query.where(AppState.client == client)
        rows = (await self.session.scalars(query.order_by(AppState.id))).all()
        return [AppStateSettingDto.model_validate(row, from_attributes=True) for row in rows]

    async def upsert(self, settings: builtins.list[AppStateSettingDto]) -> None:
        for setting in settings:
            query = select(AppState).where(AppState.key == setting.key,
                                           AppState.tag.is_(setting.tag) if setting.tag is None else AppState.tag == setting.tag,
                                           AppState.client.is_(setting.client) if setting.client is None else AppState.client == setting.client)
            row = await self.session.scalar(query)
            if row is None:
                self.session.add(AppState(**setting.model_dump(by_alias=False)))
            else:
                row.value = setting.value
        await self.session.commit()

    async def delete(self, key: str | None, tag: str | None, client: str | None) -> int:
        """Delete the rows ``list`` would return for the same filters."""
        statement = sql_delete(AppState)
        if key is not None:
            statement = statement.where(AppState.key == key)
        if tag is not None:
            statement = statement.where(AppState.tag == tag)
        if client is not None:
            statement = statement.where(AppState.client == client)
        result = await self.session.execute(statement)
        await self.session.commit()
        return result.rowcount or 0
