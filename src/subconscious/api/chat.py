import time
import uuid
from sqlalchemy.ext.asyncio import AsyncSession
from fastapi import APIRouter, HTTPException, Depends

from .models import (
  ChatMessage,
  ChatCompletionUsage,
  ChatResponseRequest,
  ChatCompletionChoice,
  ChatCompletionRequest,
  ChatCompletionResponse
)
from ..engine import Engine
from ..config import Config
from ..db.session import Database
from ..db.models import Thread, Message, Workspace


router = APIRouter()


def get_config() -> Config:
  """ Dependency to get config. In a real app, this would be injected """
  # For now, create a default config
  return Config(dev=True, gui=False, tui=False)


def get_db(config: Config = Depends(get_config)) -> Database:
  """ Dependency to get database instance """
  return Database(config)


def get_engine(config: Config = Depends(get_config)) -> Engine:
  """ Dependency to get engine instance """
  return Engine(config)

@router.post("/chat/completions", response_model=ChatCompletionResponse)
async def chat_completions(
  request: ChatCompletionRequest,
  db: AsyncSession = Depends(get_db),
  engine: Engine = Depends(get_engine)
):
  """Handle chat completion requests compatible with OpenAI API format."""
  try:
    # Get or create thread
    thread = None
    if request.thread_id:
        # Try to find existing thread
        result = await db.execute(
            Thread.__table__.select().where(Thread.uuid == request.thread_id)
        )
        thread = result.fetchone()
        if thread:
            thread = Thread(**thread)

    if not thread:
        # Create new thread
        workspace_id = None
        if request.workspace_id:
            # Find workspace
            result = await db.execute(
                Workspace.__table__.select().where(Workspace.uuid == request.workspace_id)
            )
            workspace = result.fetchone()
            if workspace:
                workspace_id = workspace.id

        thread = Thread(
            workspace_id=workspace_id,
            title=f"Chat {uuid.uuid4().hex[:8]}",
            default_model_id=request.model
        )
        db.add(thread)
        await db.commit()
        await db.refresh(thread)

    # Store user message
    user_message = Message(
        thread_id=thread.id,
        role="user",
        content=request.messages[-1].content if request.messages else ""
    )
    db.add(user_message)
    await db.commit()

    # Generate response using engine
    # This is a simplified implementation - you'll need to integrate with your actual engine
    response_content = await engine.generate_response(
        messages=request.messages,
        model=request.model,
        temperature=request.temperature,
        max_tokens=request.max_tokens
    )

    # Store assistant message
    assistant_message = Message(
        thread_id=thread.id,
        role="assistant",
        content=response_content
    )
    db.add(assistant_message)
    await db.commit()

    # Create response
    completion_id = f"chatcmpl-{uuid.uuid4().hex}"
    created_time = int(time.time())

    response = ChatCompletionResponse(
        id=completion_id,
        created=created_time,
        model=request.model,
        choices=[
            ChatCompletionChoice(
                index=0,
                message=ChatMessage(role="assistant", content=response_content),
                finish_reason="stop"
            )
        ],
        usage=ChatCompletionUsage(
            prompt_tokens=len(request.messages),
            completion_tokens=len(response_content.split()),
            total_tokens=len(request.messages) + len(response_content.split())
        )
    )

    return response
  except Exception as e:
    raise HTTPException(status_code=500, detail=str(e))

@router.post("/chat/responses")
async def chat_responses(
  request: ChatResponseRequest,
  db: AsyncSession = Depends(get_db),
  engine: Engine = Depends(get_engine)
):
  """Handle additional chat responses."""
  try:
    # Find thread
    result = await db.execute(
        Thread.__table__.select().where(Thread.uuid == request.thread_id)
    )
    thread_row = result.fetchone()
    if not thread_row:
        raise HTTPException(status_code=404, detail="Thread not found")

    thread = Thread(**thread_row)

    # Generate response
    messages = [
        ChatMessage(role="user", content=request.message)
    ]

    response_content = await engine.generate_response(
        messages=messages,
        model=request.model or thread.default_model_id or "default"
    )

    # Store messages
    user_msg = Message(thread_id=thread.id, role="user", content=request.message)
    assistant_msg = Message(thread_id=thread.id, role="assistant", content=response_content)

    db.add(user_msg)
    db.add(assistant_msg)
    await db.commit()

    return {
        "thread_id": request.thread_id,
        "response": response_content,
        "model": request.model or thread.default_model_id or "default"
    }
  except Exception as e:
    raise HTTPException(status_code=500, detail=str(e))
