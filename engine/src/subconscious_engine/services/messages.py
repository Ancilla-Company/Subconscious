"""Message persistence service."""

from typing import Literal, cast
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.schemas import MessageDto, SendMessageRequest
from subconscious_engine.storage.models import ConversationThread, Message, utc_now


class MessageService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list(self, thread_uuid: str) -> list[MessageDto]:
        thread = await self.session.scalar(select(ConversationThread).where(ConversationThread.uuid == thread_uuid))
        if thread is None:
            return []
        rows = (await self.session.scalars(select(Message).where(Message.thread_id == thread.id).order_by(Message.created_at))).all()
        return [self._dto(row, thread_uuid) for row in rows]

    async def create(self, request: SendMessageRequest) -> MessageDto | None:
        thread = await self.session.scalar(select(ConversationThread).where(ConversationThread.uuid == request.thread_uuid))
        if thread is None:
            return None
        row = Message(uuid=str(uuid4()), thread_id=thread.id, role=request.role, content=request.content)
        thread.updated_at = utc_now()
        self.session.add(row)
        await self.session.commit()
        return self._dto(row, thread.uuid)

    @staticmethod
    def _dto(row: Message, thread_uuid: str) -> MessageDto:
        role = cast(Literal["user", "assistant", "system", "tool"], row.role)
        return MessageDto(uuid=row.uuid, thread_uuid=thread_uuid, role=role,
                          content=row.content, created_at=row.created_at)
