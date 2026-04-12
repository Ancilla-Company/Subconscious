from pydantic import BaseModel
from typing import Optional, List, Dict, Any


class ChatMessage(BaseModel):
  role: str  # "user", "assistant", "system"
  content: str


class ChatCompletionRequest(BaseModel):
  messages: List[ChatMessage]
  model: str = "default"
  thread_id: Optional[str] = None
  workspace_id: Optional[str] = None
  stream: bool = False
  temperature: Optional[float] = None
  max_tokens: Optional[int] = None


class ChatCompletionChoice(BaseModel):
  index: int
  message: ChatMessage
  finish_reason: Optional[str] = None


class ChatCompletionUsage(BaseModel):
  prompt_tokens: int
  completion_tokens: int
  total_tokens: int


class ChatCompletionResponse(BaseModel):
  id: str
  object: str = "chat.completion"
  created: int
  model: str
  choices: List[ChatCompletionChoice]
  usage: ChatCompletionUsage


class ChatResponseRequest(BaseModel):
  thread_id: str
  message: str
  model: Optional[str] = None


class ErrorResponse(BaseModel):
  error: Dict[str, Any]
