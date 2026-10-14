"""Message persistence service."""

from typing import Literal, cast
from uuid import uuid4

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.schemas import MessageDto, SendMessageRequest
from subconscious_engine.storage.models import ConversationThread, Message, utc_now


def message_order() -> tuple[object, ...]:
    """Thread order is (hlc, origin_node_id, uuid): identical on every node (webrtc.md 7.3)."""
    return (Message.hlc, func.coalesce(Message.origin_node_id, ""), Message.uuid)


class MessageService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list(self, thread_uuid: str) -> list[MessageDto]:
        thread = await self.session.scalar(select(ConversationThread).where(
            ConversationThread.uuid == thread_uuid, ConversationThread.deleted_at.is_(None)))
        if thread is None:
            return []
        rows = (await self.session.scalars(
            select(Message).where(Message.thread_id == thread.id, Message.deleted_at.is_(None))
            .order_by(*message_order()))).all()
        return [self._dto(row, thread_uuid) for row in rows]

    async def create(self, request: SendMessageRequest) -> MessageDto | None:
        thread = await self.session.scalar(select(ConversationThread).where(
            ConversationThread.uuid == request.thread_uuid, ConversationThread.deleted_at.is_(None)))
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
