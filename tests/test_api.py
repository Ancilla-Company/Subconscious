import pytest
from fastapi import Depends
from unittest.mock import AsyncMock
from fastapi.testclient import TestClient

from subconscious.config import Config
from subconscious.api import create_app
from subconscious.api.chat import get_db, get_engine, get_config
from subconscious.api.engine_instance import get_engine_instance


@pytest.fixture
def client(db):
  config = Config(test=True)
  app = create_app(config)

  # Mock dependencies
  def override_get_config():
    return config

  def override_get_db(config: Config = Depends(get_config)):
    return db

  async def override_get_engine(config: Config = Depends(get_config)):
    mock_engine = AsyncMock()
    mock_engine.generate_response = AsyncMock(return_value="Mock response")
    return mock_engine

  app.dependency_overrides[get_config] = override_get_config
  app.dependency_overrides[get_db] = override_get_db
  app.dependency_overrides[get_engine] = override_get_engine

  with TestClient(app) as test_client:
    yield test_client

def test_health_check(client):
  """ Test the health check endpoint """
  response = client.get("/health")
  assert response.status_code == 200
  assert response.json() == {"status": "healthy", "service": "subconscious-api"}

def test_chat_completions_success(client):
  """ Test successful chat completions request """
  request_data = {
    "messages": [{"role": "user", "content": "Hello, how are you?"}],
    "model": "test-model"
  }
  response = client.post("/api/v1/chat/completions", json=request_data)
  assert response.status_code == 200
  data = response.json()
  assert "id" in data
  assert data["object"] == "chat.completion"
  assert data["model"] == "test-model"
  assert "thread_id" in data
  assert len(data["choices"]) == 1
  assert data["choices"][0]["index"] == 0
  assert data["choices"][0]["message"]["role"] == "assistant"
  assert data["choices"][0]["message"]["content"] == "Mock response"
  assert data["choices"][0]["finish_reason"] == "stop"
  assert "usage" in data
  assert data["usage"]["prompt_tokens"] == 1
  assert data["usage"]["completion_tokens"] == 2  # "Mock response".split() has 2 words
  assert data["usage"]["total_tokens"] == 3

def test_chat_responses_success(client):
  """ Test successful chat responses request """
  # First, create a thread via chat completions
  completions_data = {
    "messages": [{"role": "user", "content": "Hello"}],
    "model": "test-model"
  }
  completions_response = client.post("/api/v1/chat/completions", json=completions_data)
  assert completions_response.status_code == 200
  completions_data = completions_response.json()
  thread_id = completions_data["thread_id"]

  # Now, test chat responses with the existing thread
  request_data = {
    "thread_id": thread_id,
    "message": "How are you?"
  }
  response = client.post("/api/v1/chat/responses", json=request_data)
  assert response.status_code == 200
  data = response.json()
  assert data["thread_id"] == thread_id
  assert data["response"] == "Mock response"
  assert data["model"] == "test-model"

def test_chat_responses_thread_not_found(client):
  """ Test chat responses with non-existing thread """
  request_data = {
    "thread_id": "non-existing-thread",
    "message": "Hello"
  }
  response = client.post("/api/v1/chat/responses", json=request_data)
  assert response.status_code == 404
  assert response.json() == {"detail": "Thread not found"}
