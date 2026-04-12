import time
import uuid
from sqlalchemy import select
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
from .engine_instance import get_engine_instance
from ..db.models import Thread, Message, Workspace, Networks, AppState


router = APIRouter()


def get_config() -> Config:
  """ Dependency to get config. In a real app, this would be injected """
  # For now, create a default config
  return Config(dev=True, gui=False, tui=False)

def get_db(config: Config = Depends(get_config)) -> Database:
  """ Dependency to get database instance """
  return Database(config)

async def get_db_session(db: Database = Depends(get_db)):
  """ Dependency to get database session """
  session = db.get_session()
  try:
    yield session
  finally:
    await session.close()

async def get_engine(config: Config = Depends(get_config)) -> Engine:
  """ Dependency to get the global engine instance """
  return await get_engine_instance(config)

async def get_default_workspace_id(session: AsyncSession) -> int:
  """Get the default workspace id from the current network."""
  # Get current network uuid
  result = await session.execute(select(AppState.value).where(AppState.key == "current_network"))
  network_uuid = result.scalar_one_or_none()
  if not network_uuid:
    raise HTTPException(status_code=500, detail="No current network set")

  # Get network
  result = await session.execute(select(Networks).where(Networks.uuid == network_uuid))
  network = result.scalar_one_or_none()
  if not network or not network.default_workspace_uuid:
    raise HTTPException(status_code=500, detail="No default workspace set")

  # Get workspace
  result = await session.execute(select(Workspace).where(Workspace.uuid == network.default_workspace_uuid))
  workspace = result.scalar_one_or_none()
  if not workspace:
    raise HTTPException(status_code=500, detail="Default workspace not found")

  return workspace.id

@router.post("/chat/completions", response_model=ChatCompletionResponse)
async def chat_completions(
  request: ChatCompletionRequest,
  session = Depends(get_db_session),
  engine: Engine = Depends(get_engine)
):
  """Handle chat completion requests compatible with OpenAI API format."""
  try:
    # Get or create thread
    thread = None
    if request.thread_id:
        # Try to find existing thread
        result = await session.execute(select(Thread).where(Thread.uuid == request.thread_id))
        thread = result.scalar_one_or_none()

    if not thread:
        # Create new thread
        if request.workspace_id:
            # Find workspace
            result = await session.execute(select(Workspace).where(Workspace.uuid == request.workspace_id))
            workspace = result.scalar_one_or_none()
            if not workspace:
                raise HTTPException(status_code=400, detail="Workspace not found")
            workspace_id = workspace.id
        else:
            # Use default workspace
            workspace_id = await get_default_workspace_id(session)

        thread = Thread(
            workspace_id=workspace_id,
            title=f"Chat {uuid.uuid4().hex[:8]}",
            default_model_id=request.model
        )
        session.add(thread)
        await session.commit()
        await session.refresh(thread)

    # Store user message
    user_message = Message(
        thread_id=thread.id,
        role="user",
        content=request.messages[-1].content if request.messages else ""
    )
    session.add(user_message)
    await session.commit()

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
    session.add(assistant_message)
    await session.commit()

    # Create response
    completion_id = f"chatcmpl-{uuid.uuid4().hex}"
    created_time = int(time.time())

    response = ChatCompletionResponse(
        id=completion_id,
        created=created_time,
        model=request.model,
        thread_id=thread.uuid,
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
  session = Depends(get_db_session),
  engine: Engine = Depends(get_engine)
):
  """Handle additional chat responses."""
  # Find thread
  result = await session.execute(select(Thread).where(Thread.uuid == request.thread_id))
  thread = result.scalar_one_or_none()
  if not thread:
      raise HTTPException(status_code=404, detail="Thread not found")

  try:
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

    session.add(user_msg)
    session.add(assistant_msg)
    await session.commit()

    return {
        "thread_id": request.thread_id,
        "response": response_content,
        "model": request.model or thread.default_model_id or "default"
    }
  except Exception as e:
    raise HTTPException(status_code=500, detail=str(e))
