import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from ..config import Config
from .chat import router as chat_router


def create_app(config: Config) -> FastAPI:
  """Create and configure the FastAPI application."""
  app = FastAPI(
    title="Subconscious API",
    description="API for Subconscious distributed AI platform",
    version="1.0.0"
  )

  # CORS middleware for VS Code extension
  origins = [
    "vscode-webview://",  # VS Code webviews
    "http://localhost:*",  # Local development
    "https://localhost:*",
    os.getenv("FRONTEND_URL", "http://localhost:4200"),  # Web UI
  ]

  app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
  )

  # Include routers
  app.include_router(chat_router, prefix="/api/v1", tags=["chat"])

  @app.get("/health")
  async def health_check():
    """Health check endpoint."""
    return {"status": "healthy", "service": "subconscious-api"}

  return app
