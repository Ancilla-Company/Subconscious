import os
import re
import sys
import uuid
import json
import time
import httpx
import shutil
import zipfile
import asyncio
import logging
import pathlib
import threading
import docx as _docx
import pypdf as _pypdf
import openpyxl as _openpyxl
from datetime import datetime
from sqlalchemy import select
from packaging.version import Version
from typing import AsyncIterator, Optional
from sqlalchemy import update as sql_update
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from pydantic_ai import Agent
from pydantic_ai.messages import (
  ModelMessage, ModelRequest, ModelResponse,
  FunctionToolCallEvent, FunctionToolResultEvent,
  UserPromptPart, TextPart, PartStartEvent, PartDeltaEvent, TextPartDelta,
)
from pydantic_ai.tools import DeferredToolRequests, DeferredToolResults

from .config import Config
from .api import APIService
from .events import EventBus
from .jobs import JobManager
from .indexing import WorkspaceIndexer
from .rag import WorkspaceRetriever, SidecarStore, get_default_embedder
from .rag import graph as kg
from .constants import VERSION
from .db.session import Database
from .agent import AgentManager, EchoProvider
from .system_info import SystemInformationService
from .stream_events import (
  TextDelta, ToolCallStarted, ToolCallResult, ApprovalRequest, ApprovalResolved, StreamEvent,
)
from .tools import classify_operation
from .desktop_tools import ToolRegistry, EngineContext
from .db.models import (
  Workspace, Thread, Message, AppState, Networks,
  SkillRegistry, ToolRegistry as ToolRegistryModel,
)


# Logging setup
logger = logging.getLogger("subconscious")


class Engine:
  """ Subconscious Engine Core """
  update_available = None
  latest_version: Optional[str] = None

  # Default inactivity timeout (seconds) for LLM streaming
  # Could be an issue for slow systems where nothing is wrong but response takes very long
  _DEFAULT_STREAM_TIMEOUT = 90.0

  # ---- Context-window management -----------------------------------------
  # Conservative default window (tokens) when a model config doesn't specify
  # one. 8k covers most local/older models; users can raise it per-model.
  _DEFAULT_CONTEXT_WINDOW = 8192
  # Never budget below this — guards against absurdly small configured values.
  _MIN_CONTEXT_WINDOW = 1024
  # Share of the window reserved for the model's response (input can't use it).
  _OUTPUT_RESERVE_RATIO = 0.25
  # Hard cap on reserved output tokens so huge windows still allow big inputs.
  _MAX_OUTPUT_RESERVE = 4096
  # Fixed safety margin (tokens) for message framing / tool schemas we can't
  # measure precisely from here.
  _CONTEXT_SAFETY_MARGIN = 512
  # Rough chars-per-token used by the heuristic token estimator.
  _CHARS_PER_TOKEN = 4

  # ---- Directory change detection ----------------------------------------
  _DEFAULT_INDEX_INTERVAL_MIN = 15.0
  # Background indexing only needs an occasional heartbeat,
  _PROGRESS_MIN_INTERVAL = 10  # seconds between progress events

  # In-memory cache of the `share_system_context` privacy toggle. Seeded at
  _share_system_context: bool = True

  # The system information service, created during start_engine by
  system_info: Optional["SystemInformationService"] = None

  def __init__(self):
    # Callbacks registered by the UI layer to react to setting changes in real-time.
    # key → list of async callables(key, value, tag)
    self._setting_callbacks: dict[str, list] = {}
    # In-process event bus. The local API's WebSocket fan-out (and future sync
    # module) subscribe here so changes made by any client — including the
    # in-process Flet UI — propagate live to all connected clients.
    self.events = EventBus()
    # Pending human-in-the-loop tool-approval futures, keyed by tool_call_id.
    self._pending_approvals: dict = {}
    # Decisions that arrived before a waiter was registered (race guard).
    self._approval_inbox: dict = {}
    # Background job registry (indexing, etc.). Notifies the UI via direct
    # in-process listeners — not the EventBus, which is for cross-instance sync.
    self.jobs = JobManager()
    # Main event loop, captured at start_engine so worker threads (indexing)
    # can marshal callbacks/notifications back onto it.
    self._loop: Optional[asyncio.AbstractEventLoop] = None
    # Cooperative-cancel events for running index jobs, keyed by job id, plus
    # a map of workspace_id → active index job id so a new re-index of the same
    # workspace supersedes an in-flight one instead of racing it on the sidecar.
    self._index_cancels: dict[str, threading.Event] = {}
    self._index_active: dict[int, str] = {}
    # Periodic change-detection task: re-scans attached directories while the
    # app is open so edits made mid-session are picked up without a restart.
    self._watch_task: Optional[asyncio.Task] = None

  def register_setting_callback(self, key: str, callback) -> None:
    """ Register an async callback to be invoked when *key* is updated via update_setting """
    self._setting_callbacks.setdefault(key, []).append(callback)

  def unregister_setting_callback(self, key: str, callback) -> None:
    """Remove a previously registered callback."""
    if key in self._setting_callbacks:
      try:
        self._setting_callbacks[key].remove(callback)
      except ValueError:
        pass

  async def init_settings(self):
    """ Initialize settings from settings.json to AppState if not present """
    try:
      system_settings = {
        "mode": [ "auto", "light", "dark" ],
        "colour": ["default", "purple", "blue", "teal", "green", "yellow", "orange", "red", "pink"],
        "language": [ "en" ],
        "position": [ "x", "y" ],
        "size": [ "width", "height" ],
        "maximized": [ False, True ],
        "share_system_context": [ "true", "false" ]
      }
      
      # Create or skip config
      async with self.db.get_session() as session:
        for key, value in system_settings.items():
          exists = await session.scalar(
            select(AppState).where(AppState.key == key, AppState.tag == "system")
          )
          
          if not exists:
            logger.info("Creating database and configuring system settings...")
            default_value = value[0]
            new_setting = AppState(key=key, value=str(default_value), tag="system")
            session.add(new_setting)
            logger.debug(f"Initialized system setting: {key}={default_value}")
        
        await session.commit()
    except Exception as e:
      logger.error(f"Failed to initialize settings: {e}")

    # Seed the in-memory privacy toggle from the (now-ensured) stored value and
    # register the callback that keeps it fresh on later updates (Req 7.5).
    await self._seed_share_system_context()

  async def _seed_share_system_context(self) -> None:
    """ Seed the _share_system_context cache from AppState and register the
    update callback.

    A failed read leaves the cache at its default (True) and a malformed stored
    registered regardless so later updates always refresh the cache.
    """
    try:
      stored = await self.get_setting("share_system_context", tag="system")
      self._share_system_context = stored == "true"
    except Exception as exc:
      logger.warning(f"Failed to seed share_system_context; using default (True): {exc}")
      self._share_system_context = True
    self.register_setting_callback(
      "share_system_context", self._on_share_system_context_changed
    )

  async def _on_share_system_context_changed(self, key: str, value: str, tag: str) -> None:
    """ Setting callback: refresh the in-memory share_system_context cache """
    self._share_system_context = value == "true"

  async def _collect_info(self) -> None:
    """ Initiates the hardware information collection service """
    try:
      self.system_info = SystemInformationService(data_dir=str(self.config.data_dir))
      # Fast, non-blocking: serve last-known data (or an UNKNOWN placeholder).
      self.system_info.load_cached_profile()

      # Refresh in the background so a slow collection never blocks startup.
      asyncio.create_task(self._refresh_system_info())
    except Exception as exc:
      logger.error(
        f"System information initialization failed; continuing without it: {exc}"
      )
      self.system_info = None

  async def _refresh_system_info(self) -> None:
    """ Run the (potentially slow) system-info collection off the event loop """
    if self.system_info is None: return
    try:
      await asyncio.to_thread(self.system_info.refresh)
      logger.debug("System information refreshed in background")
    except Exception as exc:
      logger.warning(f"Background system-info refresh failed: {exc}")

  async def init_system(self):
    """ Initialize system components (DB, Default Workspace) """
    async with self.db.get_session() as session:
      # Find current network inside app_state
      self.current_network = await session.scalar(
        select(AppState).where(AppState.key == "current_network")
      )
      
      network = None
      if self.current_network:
        network = await session.scalar(
          select(Networks).where(Networks.uuid == self.current_network.value)
        )
      
      if not network:
        # Load the first network in the table
        network = await session.scalar(select(Networks))
        
        # If no networks exist, create one
        if not network:
          default_workspace_uuid = str(uuid.uuid4())
          network = Networks(
            name="General Network",
            uuid=str(uuid.uuid4()),
            description="Default network created on first run",
            default_workspace_uuid=default_workspace_uuid,
          )
          session.add(network)
          await session.flush() # ensure network has id if needed
          
          # Update app state
          if self.current_network:
            self.current_network.value = network.uuid
          else:
            self.current_network = AppState(key="current_network", value=network.uuid)
            session.add(self.current_network)

          logger.debug(f"Created new default network: {network.uuid}")

      # Check if default workspace exists
      workspace = await session.scalar(
        select(Workspace).where(
          Workspace.uuid == network.default_workspace_uuid,
          Workspace.network_id == network.id
        )
      )
      
      if not workspace:
        logger.debug("Creating default 'General' workspace.")
        workspace = Workspace(
          name="General",
          network_id=network.id,
          description="Default workspace for general conversations",
          uuid=network.default_workspace_uuid
        )
        session.add(workspace)

      # If we found an existing network but app_state wasn't set, update it
      if network and not self.current_network:
        self.current_network = AppState(key="current_network", value=network.uuid)
        session.add(self.current_network)
      elif network and self.current_network.value != network.uuid:
        self.current_network.value = network.uuid

      await session.commit()

  async def start_engine(self, config: Config):
    """ Engine startup logic """
    # Initialize and load config
    self.config = config
    self.config.load()

    # Capture the running loop so worker threads (e.g. indexing) can marshal
    # progress events and notifications back onto it, and let the job manager
    # publish live updates from those threads.
    self._loop = asyncio.get_running_loop()
    self.jobs.set_loop(self._loop)

    # Init the database
    self.db = Database(config)
    await self.db.init_models()

    # Init the default settings
    await self.init_settings()

    # Initialize the system data
    await self.init_system()

    # Collect the hardware info
    await self._collect_info()

    # Check for updates
    asyncio.create_task(self.check_for_updates())

    # Initialize Agent Manager
    self.agent_manager = AgentManager(config)

    # Initialize Tool Registry
    self.tool_registry = ToolRegistry()

    # Workspace directory indexer (RAG ingestion)
    self.embedder = get_default_embedder()
    cache_dir = str(self.config.data_dir)
    self.indexer = WorkspaceIndexer(self.embedder, cache_dir=cache_dir)
    self.retriever = WorkspaceRetriever(self.embedder, cache_dir=cache_dir)

    # Periodic incremental re-index of attached directories (change detection).
    self._watch_task = asyncio.create_task(self._directory_watch_loop())

    # Start the API background service
    self.api_service = APIService(self, self.config, preferred_port=8771)
    await self.api_service.start()

    # Start the heartbeat: DEBUG
    if self.config.dev:
      self._heartbeat_task = asyncio.create_task(self.heartbeat())

    # Show ready notification: DEBUG
    if self.config.dev:
      await self.show_notification("Subconscious", "Startup Complete.")

  async def stop_api(self) -> None:
    """ Stop the local API service if it is running """
    service = getattr(self, "api_service", None)
    if service is not None:
      await service.stop()

  async def restart_api(self) -> None:
    """ Restart the local API service (stop then start again) """
    service = getattr(self, "api_service", None)
    if service is not None:
      await service.restart()

  async def get_or_create_thread(
    self,
    content: str,
    workspace_id: int,
    thread_id: Optional[int] = None,
  ) -> Thread:
    """
    If thread_id is given and the thread exists, return it.
    Otherwise create a new Thread in the given workspace with a
    placeholder title derived from the first message.
    """
    async with self.db.get_session() as session:
      if thread_id:
        thread = await session.get(Thread, thread_id)
        if thread:
          return thread

      # Auto-generate a short title from the first few words
      words = content.strip().split()
      title = " ".join(words[:6])
      if len(words) > 6:
        title += "…"
      if not title:
        title = "New Thread"

      thread = Thread(
        workspace_id=workspace_id,
        title=title,  # type: ignore[arg-type]
        description=None,
      )
      session.add(thread)
      await session.commit()
      await session.refresh(thread)
      workspace = await session.get(Workspace, workspace_id)
      workspace_uuid = workspace.uuid if workspace else None

    await self.events.publish({
      "type": "thread.created",
      "data": {
        "uuid": thread.uuid,
        "workspace_uuid": workspace_uuid,
        "title": thread.title,
        "created_at": thread.created_at.isoformat() if thread.created_at else None,
        "updated_at": thread.updated_at.isoformat() if thread.updated_at else None,
      },
    })
    return thread

  async def save_message(self, thread_id: int, role: str, content: str) -> Message:
    """Persist a single message and return the ORM object. Also bumps the thread's updated_at."""
    async with self.db.get_session() as session:
      msg = Message(thread_id=thread_id, role=role, content=content)
      session.add(msg)
      # Bump the parent thread's updated_at so the list stays sorted by recent activity
      await session.execute(
        sql_update(Thread)
        .where(Thread.id == thread_id)
        .values(updated_at=datetime.now())
      )
      await session.commit()
      await session.refresh(msg)
      thread = await session.get(Thread, thread_id)
      thread_uuid = thread.uuid if thread else None

    # Notify connected clients (VS Code extension, etc.) of the new message.
    await self.events.publish({
      "type": "message.created",
      "data": {
        "uuid": msg.uuid,
        "thread_uuid": thread_uuid,
        "role": role,
        "content": content,
        "created_at": msg.created_at.isoformat() if msg.created_at else None,
      },
    })
    return msg

  async def load_thread_messages(self, thread_id: int) -> list[Message]:
    """Return all messages for a thread ordered chronologically."""
    async with self.db.get_session() as session:
      result = await session.scalars(
        select(Message)
        .where(Message.thread_id == thread_id)
        .order_by(Message.created_at)
      )
      return list(result.all())

  def _build_history(self, db_messages: list[Message]) -> list[ModelMessage]:
    """
    Convert stored Message rows into the pydantic-ai message history format
    so the LLM has full conversation context.
    """
    history: list[ModelMessage] = []
    for msg in db_messages:
      content_str = str(msg.content)
      if msg.role == "user":
        history.append(ModelRequest(parts=[UserPromptPart(content=content_str)]))
      elif msg.role in ("assistant", "agent"):
        history.append(ModelResponse(parts=[TextPart(content=content_str)]))
    return history

  async def stream_chat_events(
    self,
    content: str,
    thread_id: int,
    model_cfg: Optional[dict] = None,
    workspace_id: Optional[int] = None,
    attachments: Optional[list[dict]] = None,
    enabled_tools: Optional[list[str]] = None,
    auto_approve: Optional[bool] = None,
  ) -> AsyncIterator[StreamEvent]:
    """
    Stream a *structured* AI response for *content* given the thread history.

    """
    # Load history (excluding the message we're about to send – it was just saved)
    db_messages = await self.load_thread_messages(thread_id)
    # Drop the last message (the user message we just persisted) so it's only
    # included as the explicit new prompt, not duplicated in history.
    history = self._build_history(db_messages[:-1])

    # Resolve model config
    if model_cfg is None:
      model_cfg = self.agent_manager.get_best_model_cfg()
    if model_cfg is None:
      raise ValueError("No model configured. Add a model in Settings → Models.")

    # Resolve tools
    if enabled_tools is not None:
      tools = self.tool_registry.get_tools(enabled_tools)
    else:
      # Resolve the effective tools_config (thread override else workspace
      # defaults) and build the enabled callables from it.
      cfg = await self.resolve_tools_config(workspace_id, thread_id)
      tools = self.tool_registry.get_tools_for_config(cfg)
    

    ambient_context = (
      self.system_info.format_ambient_context()
      if self._share_system_context and self.system_info is not None
      else None
    )
    agent = self.agent_manager.build_agent(
      model_cfg,
      tools=tools,
      ambient_context=ambient_context,
    )

    # Build the dependency context for tools that need DB / workspace access
    ctx_deps = EngineContext(
      db=self.db,
      workspace_id=workspace_id or 0,
      thread_id=thread_id,
      engine=self,
      data_dir=str(self.config.data_dir),
      approval_config=await self.resolve_approval_config(workspace_id, thread_id),
    )

    # ---- Fit everything within the model's context window ------------------
    # Budget = window − reserved output − (system prompt + ambient + margin).
    # Attachments get a share of the remaining input budget (degrading their
    # inlining tier to fit), then history is trimmed oldest-first to whatever
    # is left. Smaller configured windows simply trim more aggressively — the
    # "course of action" when a user lowers the limit to avoid overruns.
    system_prompt = (model_cfg.get("system_prompt") or "") if model_cfg else ""
    input_budget = self._input_token_budget(model_cfg, system_prompt, ambient_context)

    # Reserve up to ~60% of the input budget for the new prompt + attachments;
    # the user's own message is always kept in full.
    attachment_token_budget = max(0, int(input_budget * 0.6) - self._estimate_tokens(content))
    prompt = self._build_prompt_with_attachments(
      content, attachments or [], char_budget=attachment_token_budget * self._CHARS_PER_TOKEN
    )

    # Remaining budget goes to conversation history (trim oldest-first to fit).
    history_budget = max(0, input_budget - self._estimate_tokens(prompt))
    history = self._fit_history_to_budget(history, history_budget)

    # Stream with an inactivity timeout. `asyncio.timeout` bounds the wait for
    #
    # We drive the full agent graph with `agent.iter()` rather than
    timeout_s = self._resolve_stream_timeout(model_cfg)
    loop = asyncio.get_running_loop()
    timeout_s = self._resolve_stream_timeout(model_cfg)
    loop = asyncio.get_running_loop()

    # The dev-only echo agent doesn't implement the graph API (no tools/HITL).
    if isinstance(agent, EchoProvider):
      try:
        async with asyncio.timeout(timeout_s) as stream_timeout:
          async with agent.run_stream(prompt) as result:
            async for chunk in result.stream_text():
              stream_timeout.reschedule(loop.time() + timeout_s)
              yield TextDelta(content=chunk)
      except asyncio.TimeoutError as exc:
        raise TimeoutError(
          f"The model did not respond within {timeout_s:.0f}s of inactivity. "
          "The provider may be unavailable or stalled."
        ) from exc
      return

    # Real agent: drive the full graph. When the model calls a tool that the
    # approval policy gates, the run ends with a DeferredToolRequests output
    # instead of executing it; we surface an ApprovalRequest, wait for the
    # user's decision (outside the inactivity timeout), then resume the run
    # with the decision until no further approvals are pending.
    deferred_results: Optional[DeferredToolResults] = None
    message_history = history
    user_prompt: Optional[str] = prompt
    while True:
      try:
        async with asyncio.timeout(timeout_s) as stream_timeout:
          async with agent.iter(  # type: ignore[call-overload]
            user_prompt,
            message_history=message_history,
            deps=ctx_deps,
            deferred_tool_results=deferred_results,
          ) as run:
            async for node in run:
              if Agent.is_model_request_node(node):
                # Stream text as the model produces it for this request node.
                async with node.stream(run.ctx) as request_stream:
                  async for event in request_stream:
                    delta: Optional[str] = None
                    if isinstance(event, PartStartEvent) and isinstance(event.part, TextPart):
                      delta = event.part.content
                    elif isinstance(event, PartDeltaEvent) and isinstance(event.delta, TextPartDelta):
                      delta = event.delta.content_delta
                    if delta:
                      stream_timeout.reschedule(loop.time() + timeout_s)
                      yield TextDelta(content=delta)
              elif Agent.is_call_tools_node(node):
                # Surface each tool call and its result as discrete events so
                # the UI can render them as their own bubbles.
                async with node.stream(run.ctx) as tool_stream:
                  async for event in tool_stream:
                    stream_timeout.reschedule(loop.time() + timeout_s)
                    if isinstance(event, FunctionToolCallEvent):
                      yield ToolCallStarted(
                        tool_name=event.part.tool_name,
                        args=event.part.args,
                        tool_call_id=event.part.tool_call_id,
                      )
                    elif isinstance(event, FunctionToolResultEvent):
                      result = event.result
                      yield ToolCallResult(
                        tool_name=getattr(result, "tool_name", "") or "",
                        content=getattr(result, "content", None),
                        tool_call_id=event.tool_call_id,
                        outcome=getattr(result, "outcome", "success"),
                      )
      except asyncio.TimeoutError as exc:
        raise TimeoutError(
          f"The model did not respond within {timeout_s:.0f}s of inactivity. "
          "The provider may be unavailable or stalled."
        ) from exc

      # If the model called any approval-gated tools, the run paused here.
      output = getattr(run.result, "output", None)
      if isinstance(output, DeferredToolRequests) and output.approvals:
        logger.debug(
          "Run paused for approval: %s",
          [c.tool_name for c in output.approvals],
        )
        decisions: dict = {}
        for call in output.approvals:
          # Surface the request, then obtain the decision. Interactive mode
          # waits (unbounded by the model timeout) for the UI; auto modes
          # resolve immediately so non-interactive consumers never stall.
          yield ApprovalRequest(
            tool_name=call.tool_name,
            args=call.args,
            tool_call_id=call.tool_call_id,
            operation=classify_operation(call.tool_name),
          )
          if auto_approve is None:
            approved = await self._await_approval(call.tool_call_id)
          else:
            approved = bool(auto_approve)
          logger.debug("Approval for %s (%s) -> %s", call.tool_name, call.tool_call_id, approved)
          yield ApprovalResolved(tool_call_id=call.tool_call_id, approved=approved)
          decisions[call.tool_call_id] = approved
        # Resume the run with the decisions and continue streaming.
        deferred_results = DeferredToolResults(approvals=decisions)
        message_history = run.result.all_messages()
        user_prompt = None
        continue
      break

  async def stream_chat(
    self,
    content: str,
    thread_id: int,
    model_cfg: Optional[dict] = None,
    workspace_id: Optional[int] = None,
    attachments: Optional[list[dict]] = None,
    enabled_tools: Optional[list[str]] = None,
  ) -> AsyncIterator[str]:
    """
    Stream an AI response for *content* as plain text chunks.

    This is a thin, backward-compatible wrapper over
    :meth:`stream_chat_events` that yields only the model's narration text
    (``TextDelta`` content), dropping tool-call/result events. The API and web
    consumers rely on this text-only contract.

    Args:
      content:       The user message text.
      thread_id:     ID of the active thread (used to load history).
      workspace_id:  ID of the active workspace (used as tool scope).
      model_cfg:     Override model config dict; uses best available if None.
      enabled_tools: List of tool slugs to attach, e.g. ['time', 'calculator'].
                     Defaults to all registered tools when None.
      attachments:   List of dicts with keys 'path' and 'type' ('file'|'folder')
                     selected by the user from the chat input. File contents and
                     directory listings are inlined into the prompt context so the
                     model can reason about them immediately without additional
                     tool calls.
    """
    async for event in self.stream_chat_events(
      content=content,
      thread_id=thread_id,
      model_cfg=model_cfg,
      workspace_id=workspace_id,
      attachments=attachments,
      enabled_tools=enabled_tools,
      auto_approve=True,
    ):
      if isinstance(event, TextDelta):
        yield event.content

  def _resolve_stream_timeout(self, model_cfg: Optional[dict]) -> float:
    """Resolve the streaming inactivity timeout (seconds).

    Precedence: ``model_cfg['stream_timeout']`` → the
    ``SUBCONSCIOUS_STREAM_TIMEOUT`` env var → ``_DEFAULT_STREAM_TIMEOUT``.
    Non-positive or unparseable values fall back to the default.
    """
    raw = model_cfg.get("stream_timeout") if model_cfg else None
    if raw in (None, ""):
      raw = os.environ.get("SUBCONSCIOUS_STREAM_TIMEOUT")
    try:
      val = float(raw) if raw not in (None, "") else self._DEFAULT_STREAM_TIMEOUT
    except (TypeError, ValueError):
      val = self._DEFAULT_STREAM_TIMEOUT
    return val if val > 0 else self._DEFAULT_STREAM_TIMEOUT

  # ------------------------------------------------------------------
  # Context-window budgeting
  # ------------------------------------------------------------------

  def _resolve_context_window(self, model_cfg: Optional[dict]) -> int:
    """Resolve the model's context window (tokens).

    Precedence: ``model_cfg['context_window']`` → ``SUBCONSCIOUS_CONTEXT_WINDOW``
    env var → ``_DEFAULT_CONTEXT_WINDOW``. Values are clamped to a sane floor so
    a mistyped tiny value can't make budgeting nonsensical.
    """
    raw = model_cfg.get("context_window") if model_cfg else None
    if raw in (None, ""):
      raw = os.environ.get("SUBCONSCIOUS_CONTEXT_WINDOW")
    try:
      val = int(float(raw)) if raw not in (None, "") else self._DEFAULT_CONTEXT_WINDOW
    except (TypeError, ValueError):
      val = self._DEFAULT_CONTEXT_WINDOW
    return max(self._MIN_CONTEXT_WINDOW, val)

  def _estimate_tokens(self, text: Optional[str]) -> int:
    """Heuristic token count (~4 chars/token). Cheap and dependency-free.

    Deliberately conservative: we round up so we under-fill rather than
    overrun the real tokenizer.
    """
    if not text:
      return 0
    return (len(text) // self._CHARS_PER_TOKEN) + 1

  def _input_token_budget(
    self,
    model_cfg: Optional[dict],
    system_prompt: Optional[str],
    ambient_context: Optional[str],
  ) -> int:
    """Tokens available for prompt + attachments + history for this request."""
    window = self._resolve_context_window(model_cfg)
    output_reserve = min(int(window * self._OUTPUT_RESERVE_RATIO), self._MAX_OUTPUT_RESERVE)
    overhead = (
      self._estimate_tokens(system_prompt)
      + self._estimate_tokens(ambient_context)
      + self._CONTEXT_SAFETY_MARGIN
    )
    budget = window - output_reserve - overhead
    # Always leave room for at least a modest prompt even on tiny windows.
    return max(256, budget)

  @staticmethod
  def _message_text(msg: ModelMessage) -> str:
    """Best-effort extraction of the text content of a history message."""
    parts = getattr(msg, "parts", None) or []
    chunks: list[str] = []
    for part in parts:
      content = getattr(part, "content", None)
      if isinstance(content, str):
        chunks.append(content)
      elif content is not None:
        chunks.append(str(content))
    return "\n".join(chunks)

  def _fit_history_to_budget(
    self, history: list[ModelMessage], budget_tokens: int
  ) -> list[ModelMessage]:
    """Trim conversation history to fit *budget_tokens*, dropping oldest first.

    Preserves the most recent exchanges (which matter most for coherence) and
    discards the oldest messages until the estimated total fits. Returns the
    kept messages in their original chronological order.
    """
    if not history or budget_tokens <= 0:
      return [] if budget_tokens <= 0 else history

    kept_reversed: list[ModelMessage] = []
    used = 0
    for msg in reversed(history):
      cost = self._estimate_tokens(self._message_text(msg))
      # Keep a contiguous suffix of recent messages: stop at the first message
      # that would overflow (once at least the latest message is retained), so
      # history stays gap-free for coherence.
      if used + cost > budget_tokens and kept_reversed:
        break
      used += cost
      kept_reversed.append(msg)
    dropped = len(history) - len(kept_reversed)
    if dropped:
      logger.info(
        "Context budget: dropped %d oldest history message(s) to fit ~%d tokens",
        dropped, budget_tokens,
      )
    return list(reversed(kept_reversed))

  def _build_prompt_with_attachments(
    self, content: str, attachments: list[dict], char_budget: Optional[int] = None
  ) -> str:
    """
    Given a list of attachment dicts (each with 'path', 'type', 'name') build a
    context preamble that inlines file contents or directory listings using a
    tiered strategy based on file size:

      < 2 MB   — Full load: entire file text is inlined.
      2–10 MB  — Skeleton: structural lines + first/last 20 lines are inlined;
                 the model should use read_range() for targeted access.
      > 10 MB  — RAG hint: only metadata is inlined; the model should use
                 search_in_file() then read_range() to access content.

    When *char_budget* is provided the tiers also scale to the model's context
    window: a running budget of characters is tracked and each attachment is
    degraded (full → skeleton → RAG hint) as needed so the inlined content
    never blows the window. This is what lets a small-context model handle a
    lot of attached data — it falls back to on-demand retrieval instead of
    stuffing everything in. Directories are always listed one level deep and
    the original user message is appended at the end.
    """
    _FULL_LIMIT    =  2_000_000   #  2 MB
    _CHUNKED_LIMIT = 10_000_000   # 10 MB

    if not attachments:
      return content

    # None → unbounded (legacy behaviour); otherwise chars still available.
    remaining: Optional[int] = char_budget

    sections: list[str] = []
    for a in attachments:
      path = a.get("path", "")
      kind = a.get("type", "file")
      name = a.get("name", path)

      if kind == "file":
        try:
          p = pathlib.Path(path)
          if not p.exists() or not p.is_file():
            sections.append(f"### File: {name}\n[File not found: {path}]")
            continue

          size_bytes = p.stat().st_size
          ext = p.suffix.lower()

          # Structured formats: extract text then apply size tiers
          if ext == ".docx":
            doc = _docx.Document(p)
            text = "\n".join(para.text for para in doc.paragraphs)
          elif ext == ".xlsx":
            wb = _openpyxl.load_workbook(p, data_only=True, read_only=True)
            rows = []
            for sheet in wb.worksheets:
              rows.append(f"--- Sheet: {sheet.title} ---")
              for row in sheet.iter_rows(values_only=True):
                if any(cell is not None for cell in row):
                  rows.append("\t".join(str(c) if c is not None else "" for c in row))
            text = "\n".join(rows)
          elif ext == ".pdf":
            reader = _pypdf.PdfReader(p)
            pages = []
            for i, page in enumerate(reader.pages):
              t = page.extract_text()
              if t:
                pages.append(f"--- Page {i+1} ---\n{t}")
            text = "\n".join(pages)
          else:
            # Plain text
            raw = p.read_bytes()
            text = raw.decode("utf-8", errors="replace")

          char_count = len(text)

          # Full load only when it fits both the absolute cap and the remaining
          # budget (if budgeting is active).
          fits_budget = (remaining is None) or (char_count <= remaining)
          rag_hint = (
            f"### File: {name}\n"
            f"[RAG MODE — file is {size_bytes:,} bytes. "
            f"Use search_in_file(path='{path}', query='...') to find relevant lines, "
            f"then read_range(path='{path}', start_line=N, end_line=M) to read them.]"
          )

          if char_count <= _FULL_LIMIT and fits_budget:
            section = f"### File: {name}\n```\n{text}\n```"
            sections.append(section)
            if remaining is not None:
              remaining = max(0, remaining - char_count)

          elif char_count <= _CHUNKED_LIMIT:
            # Skeleton: structural lines + head + tail
            lines = text.splitlines()
            total = len(lines)
            if ext == ".py":
              pat = re.compile(r"^\s*(class |def |async def |@|\bimport |\bfrom )")
            elif ext in (".md", ".markdown", ".rst"):
              pat = re.compile(r"^(#{1,6} |={3,}|-{3,})")
            else:
              pat = re.compile(r"^\s*(class |def |function |public |private |export |import |from )")

            skeleton = [f"{i+1:>6}: {l}" for i, l in enumerate(lines) if pat.match(l)]
            head = [f"{i+1:>6}: {lines[i]}" for i in range(min(20, total))]
            tail = [f"{i+1:>6}: {lines[i]}" for i in range(max(0, total - 20), total)]
            body = (
              f"[SKELETON — {name} is {size_bytes:,} bytes ({total:,} lines). "
              f"Use read_range() for specific lines.]\n\n"
              "── First 20 lines ──\n" + "\n".join(head) + "\n\n"
              f"── Structural lines ({len(skeleton)} found) ──\n" + "\n".join(skeleton) + "\n\n"
              "── Last 20 lines ──\n" + "\n".join(tail)
            )
            # If even the skeleton overflows the remaining budget, fall back to
            # a RAG hint (cheap) so a small window isn't blown by one file.
            if remaining is not None and len(body) > remaining:
              sections.append(rag_hint)
              remaining = max(0, remaining - len(rag_hint))
            else:
              sections.append(f"### File: {name}\n{body}")
              if remaining is not None:
                remaining = max(0, remaining - len(body))

          else:
            sections.append(rag_hint)
            if remaining is not None:
              remaining = max(0, remaining - len(rag_hint))

        except Exception as exc:
          sections.append(f"### File: {name}\n[Error reading file: {exc}]")

      elif kind == "folder":
        try:
          p = pathlib.Path(path)
          if not p.exists() or not p.is_dir():
            sections.append(f"### Folder: {name}\n[Directory not found: {path}]")
            continue
          entries = []
          for child in sorted(p.iterdir()):
            prefix = "📁 " if child.is_dir() else "📄 "
            try:
              size = f"  ({child.stat().st_size:,} B)" if child.is_file() else ""
            except OSError:
              size = ""
            entries.append(f"  {prefix}{child.name}{size}")
          listing = "\n".join(entries) if entries else "  (empty)"
          sections.append(f"### Folder: {name} ({path})\n{listing}")
        except Exception as exc:
          sections.append(f"### Folder: {name}\n[Error listing directory: {exc}]")

    preamble = (
      "The user has attached the following files and folders. "
      "Use this content to answer their question.\n\n"
      + "\n\n".join(sections)
      + "\n\n---\n\n"
    )
    return preamble + content

  async def update_thread_title(self, thread_id: int, title: str) -> None:
    """Update the thread title (called after the first exchange if desired)."""
    async with self.db.get_session() as session:
      thread = await session.get(Thread, thread_id)
      if thread:
        thread.title = title  # type: ignore[assignment]
        await session.commit()

  async def update_thread_details(
    self,
    thread_id: int,
    title: Optional[str] = None,
    description: Optional[str] = None,
  ) -> Optional[Thread]:
    """ Update a thread's title and/or description and return the refreshed row.
    """
    async with self.db.get_session() as session:
      thread = await session.get(Thread, thread_id)
      if not thread:
        return None
      if title is not None:
        thread.title = title  # type: ignore[assignment]
      if description is not None:
        thread.description = description  # type: ignore[assignment]
      thread.updated_at = datetime.now()  # type: ignore[assignment]
      await session.commit()
      await session.refresh(thread)
      return thread

  async def get_thread_model_id(self, thread_id: int) -> Optional[str]:
    """
    Return the persisted model ID for a thread, or None if not set.
    A stored value of 'default' means the caller should resolve to the first
    available model config rather than a specific one.
    """
    async with self.db.get_session() as session:
      thread = await session.get(Thread, thread_id)
      if thread:
        return thread.default_model_id  # type: ignore[return-value]
      return None

  async def set_thread_model_id(self, thread_id: int, model_id: str) -> None:
    """
    Persist the selected model ID for a thread.
    Pass 'default' when the user has selected the first/default model so that
    future changes to the model list don't lock the thread to a stale ID.
    """
    async with self.db.get_session() as session:
      await session.execute(
        sql_update(Thread)
        .where(Thread.id == thread_id)
        .values(default_model_id=model_id)
      )
      await session.commit()

  # ------------------------------------------------------------------
  # Tool & skill configuration (workspace defaults + thread overrides)
  # ------------------------------------------------------------------

  def get_tool_catalog(self) -> dict:
    """Return the built-in tool hierarchy {slug: [{name, doc}, ...]}."""
    return self.tool_registry.catalog()

  @staticmethod
  def _parse_json_config(raw: Optional[str]) -> dict:
    """Parse a JSON config string, returning {} on null/invalid input."""
    if not raw:
      return {}
    try:
      data = json.loads(raw)
      return data if isinstance(data, dict) else {}
    except Exception:
      return {}

  @staticmethod
  def _parse_json_list(raw: Optional[str]) -> list:
    """Parse a JSON list string, returning [] on null/invalid input."""
    if not raw:
      return []
    try:
      data = json.loads(raw)
      return data if isinstance(data, list) else []
    except Exception:
      return []

  async def get_workspace_directories(self, workspace_id: int) -> list:
    """Return the list of directory paths attached to a workspace ([] if unset)."""
    if not workspace_id:
      return []
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      return self._parse_json_list(ws.directories) if ws else []

  async def set_workspace_directories(self, workspace_id: int, directories: list) -> None:
    """Persist the attached directory list; sever sidecars for detached dirs.

    When a directory is removed from the workspace its per-directory sidecar
    store (``<dir>/.subconscious/<workspace_uuid>/``) is deleted so its indexed
    documents, chunks and knowledge graph are cleanly discarded with it.
    """
    workspace_uuid: Optional[str] = None
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      if ws:
        old_dirs = self._parse_json_list(ws.directories)
        workspace_uuid = ws.uuid
        ws.directories = json.dumps(directories)
        await session.commit()
      else:
        return

    removed = [d for d in old_dirs if d not in set(directories)]
    if removed and workspace_uuid:
      cache_dir = str(self.config.data_dir)
      def _destroy():
        for d in removed:
          try:
            SidecarStore.destroy(pathlib.Path(d), workspace_uuid, cache_dir=cache_dir)
          except Exception as exc:
            logger.warning("Failed to remove sidecar for detached dir %s: %s", d, exc)
      # Filesystem work off the event loop.
      loop = self._loop or asyncio.get_event_loop()
      await loop.run_in_executor(None, _destroy)

  async def _get_workspace_uuid(self, workspace_id: int) -> Optional[str]:
    """Return the workspace's uuid (used to scope per-directory sidecars)."""
    if not workspace_id:
      return None
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      return ws.uuid if ws else None

  # ------------------------------------------------------------------
  # Retrieval (RAG) — directory indexing + search
  # ------------------------------------------------------------------

  def reindex_workspace(
    self,
    workspace_id: int,
    workspace_name: str = "workspace",
    directories: Optional[list] = None,
    notify: bool = True,
    track: bool = True,
  ) -> Optional[str]:
    """ Kick off an incremental re-index of a workspace's attached directories.

    When *track* is True a background Job is created and its progress is
    published on the EventBus for the notifications UI. Background/periodic
    scans pass ``track=False``: they run silently and publish no job events.
    This matters at cold start — a job event arriving while the Flet UI is
    still mounting forces a full re-render that drops the state the mount is
    applying, so the automatic startup scan must stay event-silent.
    """
    indexer = getattr(self, "indexer", None)
    if indexer is None:
      return None

    # Supersede any in-flight index for this workspace.
    prev_id = self._index_active.get(workspace_id)
    if prev_id and prev_id in self._index_cancels:
      self._index_cancels[prev_id].set()

    job = self.jobs.create("index", f"Indexing {workspace_name}") if track else None
    cancel = threading.Event()
    # A stable id for the cancel/active registries — the job id when tracked,
    # otherwise a synthetic one so supersede + shutdown cancellation still work.
    run_id = job.id if job else uuid.uuid4().hex
    self._index_cancels[run_id] = cancel
    self._index_active[workspace_id] = run_id
    loop = self._loop or asyncio.get_event_loop()

    async def _run():
      try:
        workspace_uuid = await self._get_workspace_uuid(workspace_id)
        if not workspace_uuid:
          if job:
            self.jobs.fail(job, "Workspace not found")
          return
        # Subset (refresh one dir) or all attached directories.
        if directories is None:
          dirs = await self.get_workspace_directories(workspace_id)
        else:
          dirs = list(directories)

        # Only publish progress when tracked. Throttle to avoid flooding the UI.
        _progress = None
        if job is not None:
          _last = {"t": 0.0}

          def _progress(current: int, total: int, message: str) -> None:
            now = time.monotonic()
            is_edge = current == 0 or current >= total
            if is_edge or now - _last["t"] >= self._PROGRESS_MIN_INTERVAL:
              _last["t"] = now
              self.jobs.update(job, current=current, total=total, message=message)

        summary = await loop.run_in_executor(
          None, indexer.reindex_sync, workspace_uuid, dirs, cancel, _progress
        )

        if summary.get("cancelled"):
          if job:
            self.jobs.update(job, message="Indexing superseded")
          # A newer run took over; leave its state alone.
          return
        if job:
          msg = f"Indexed {summary['indexed']} of {summary['total']} files"
          self.jobs.complete(job, msg)
          if notify:
            await self.show_notification("Indexing complete", f"{workspace_name}: {msg}")
        # If the workspace opted into semantic-graph building, run it now as a
        # follow-on job (it costs model calls, hence gated by the toggle). Only
        # when something actually changed, to avoid needless model calls on
        # periodic no-op scans.
        if summary.get("indexed"):
          rag_cfg = await self.get_workspace_rag_config(workspace_id)
          if rag_cfg.get("semantic_graph"):
            asyncio.create_task(self._run_semantic_graph_job(workspace_id, workspace_name))
      except Exception as exc:
        logger.error(f"Workspace indexing failed ({workspace_id}): {exc}")
        if job:
          self.jobs.fail(job, str(exc))
          if notify:
            await self.show_notification("Indexing failed", str(exc))
      finally:
        self._index_cancels.pop(run_id, None)
        if self._index_active.get(workspace_id) == run_id:
          self._index_active.pop(workspace_id, None)

    asyncio.create_task(_run())
    return run_id

  # ------------------------------------------------------------------
  # Periodic change detection for indexing
  # ------------------------------------------------------------------
  async def _directory_watch_loop(self) -> None:
    """ Periodically re-index attached directories """
    logger.debug("Directory change-detection every %.0fs", self._DEFAULT_INDEX_INTERVAL_MIN)
    try:
      while True:
        try:
          async with self.db.get_session() as session:
            rows = await session.scalars(select(Workspace))
            workspaces = [
              (w.id, w.name, self._parse_json_list(w.directories)) for w in rows.all()
            ]

          for wid, name, dirs in workspaces:
            if not dirs:
              continue

            # Don't pile onto a workspace that's already (re)indexing.
            if wid in self._index_active: continue
            # Background scan: silent + untracked so no job events fire (which
            # would disrupt the UI mount at cold start).
            self.reindex_workspace(wid, name, notify=False, track=True)
        except Exception as e:
          logger.debug("Periodic directory scan failed: %s", e)

        # Sleep for designated interval
        await asyncio.sleep(self._DEFAULT_INDEX_INTERVAL_MIN * 60)  # @IgnoreException
    except asyncio.CancelledError:
      pass

  async def search_workspace(
    self, workspace_id: int, query: str, limit: int = 8, mode: str = "hybrid"
  ) -> list[dict]:
    """Retrieve the most relevant indexed chunks for *query* within a workspace.

    Hybrid keyword + vector retrieval fanned out across every attached
    directory's sidecar store. Runs in a worker thread (sync SQLite) so the
    loop stays free. *mode* ∈ {"keyword", "vector", "hybrid"}.
    """
    if not query or not query.strip() or not workspace_id:
      return []
    workspace_uuid = await self._get_workspace_uuid(workspace_id)
    if not workspace_uuid:
      return []
    directories = await self.get_workspace_directories(workspace_id)
    if not directories:
      return []
    loop = self._loop or asyncio.get_event_loop()
    return await loop.run_in_executor(
      None, self.retriever.search, workspace_uuid, directories, query, limit, mode
    )

  async def graph_search_workspace(
    self, workspace_id: int, query: str, limit: int = 6
  ) -> dict:
    """GraphRAG retrieval: seed with hybrid search, then expand along the
    knowledge graph to gather connected context. Returns
    ``{"seeds", "related", "graph"}``.
    """
    empty = {"seeds": [], "related": [], "graph": {"nodes": [], "edges": []}}
    if not query or not query.strip() or not workspace_id:
      return empty
    workspace_uuid = await self._get_workspace_uuid(workspace_id)
    if not workspace_uuid:
      return empty
    directories = await self.get_workspace_directories(workspace_id)
    if not directories:
      return empty
    loop = self._loop or asyncio.get_event_loop()
    return await loop.run_in_executor(
      None, self.retriever.graph_search, workspace_uuid, directories, query, limit
    )

  async def build_semantic_graph(
    self,
    workspace_id: int,
    max_chunks: int = 100,
    model_cfg: Optional[dict] = None,
  ) -> dict:
    """Tier-2 knowledge graph: use the LLM to extract semantic triples from
    indexed chunks that haven't been processed yet, writing them back into each
    directory's sidecar with chunk-level provenance.

    This is opt-in (not run during normal indexing) because it costs model
    calls. It processes at most *max_chunks* pending chunks per call and can be
    invoked repeatedly to work through a large corpus incrementally.
    """
    result = {"processed": 0, "triples": 0, "chunks": 0, "skipped": False}
    if not workspace_id:
      return result
    # Gate on the workspace's opt-in toggle: when disabled the semantic graph
    # is never built (only the free structural graph from indexing remains).
    rag_cfg = await self.get_workspace_rag_config(workspace_id)
    if not rag_cfg.get("semantic_graph"):
      result["skipped"] = True
      return result
    workspace_uuid = await self._get_workspace_uuid(workspace_id)
    if not workspace_uuid:
      return result
    directories = await self.get_workspace_directories(workspace_id)
    if not directories:
      return result

    model_cfg = model_cfg or self.agent_manager.get_best_model_cfg()
    if model_cfg is None:
      raise ValueError("No model configured for semantic graph extraction.")
    agent = self.agent_manager.build_agent(
      model_cfg, tools=None, ambient_context=kg.SEMANTIC_SYSTEM_PROMPT
    )

    loop = self._loop or asyncio.get_event_loop()
    remaining = max_chunks

    for d in directories:
      if remaining <= 0:
        break
      root = pathlib.Path(d)

      # Open the sidecar (read pending chunks) in the executor.
      def _open():
        return SidecarStore.open(
          root, workspace_uuid, self.embedder.name, str(self.config.data_dir)
        )
      store = await loop.run_in_executor(None, _open)
      try:
        pending = await loop.run_in_executor(
          None, store.pending_semantic_chunks, remaining
        )
        for row in pending:
          chunk_id = row["id"]
          document_id = row["document_id"]
          content = row["content"]
          try:
            run = await agent.run(kg.build_semantic_prompt(content))
            raw = str(getattr(run, "output", "") or "")
          except Exception as exc:
            logger.debug("Semantic extraction failed for chunk %s: %s", chunk_id, exc)
            raw = ""
          triples = kg.parse_semantic_triples(raw, document_id, chunk_id)
          if triples:
            await loop.run_in_executor(None, store.add_triples, triples)
            result["triples"] += len(triples)
          await loop.run_in_executor(None, store.mark_semantic_done, [chunk_id])
          result["chunks"] += 1
          remaining -= 1
          if remaining <= 0:
            break
        result["processed"] += 1
      finally:
        await loop.run_in_executor(None, store.close)

    return result

  async def _run_semantic_graph_job(self, workspace_id: int, workspace_name: str = "workspace") -> None:
    """Build the semantic knowledge graph as a tracked background job.

    Processes pending chunks in batches until none remain (bounded by a safety
    cap). No-ops immediately when the workspace's toggle is disabled.
    """
    rag_cfg = await self.get_workspace_rag_config(workspace_id)
    if not rag_cfg.get("semantic_graph"):
      return

    job = self.jobs.create("semantic_graph", f"Building knowledge graph: {workspace_name}")
    total_chunks = 0
    total_triples = 0
    try:
      batch = 50
      max_batches = 200  # safety cap: at most 10k chunks per run
      for _ in range(max_batches):
        result = await self.build_semantic_graph(workspace_id, max_chunks=batch)
        if result.get("skipped"):
          break
        processed = result.get("chunks", 0)
        total_chunks += processed
        total_triples += result.get("triples", 0)
        self.jobs.update(
          job, message=f"{total_chunks} chunks, {total_triples} facts extracted"
        )
        if processed < batch:
          break  # drained the pending queue
      self.jobs.complete(
        job, f"Knowledge graph updated: {total_triples} facts from {total_chunks} chunks"
      )
    except Exception as exc:
      logger.error(f"Semantic graph build failed ({workspace_id}): {exc}")
      self.jobs.fail(job, str(exc))

  # ------------------------------------------------------------------
  # RAG / indexing options (per workspace)
  # ------------------------------------------------------------------

  # Semantic-graph building defaults OFF: it costs model calls, so it only runs
  # when a workspace explicitly opts in.
  _DEFAULT_RAG_CONFIG = {"semantic_graph": False}

  @classmethod
  def _normalize_rag_config(cls, cfg: Optional[dict]) -> dict:
    base = dict(cls._DEFAULT_RAG_CONFIG)
    if isinstance(cfg, dict) and "semantic_graph" in cfg:
      base["semantic_graph"] = bool(cfg["semantic_graph"])
    return base

  async def get_workspace_rag_config(self, workspace_id: int) -> dict:
    """Return the workspace RAG options (defaults when unset)."""
    if not workspace_id:
      return dict(self._DEFAULT_RAG_CONFIG)
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      raw = self._parse_json_config(ws.rag_config) if ws else {}
    return self._normalize_rag_config(raw)

  async def set_workspace_rag_config(self, workspace_id: int, config: dict) -> None:
    """Persist the workspace RAG options."""
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      if ws:
        ws.rag_config = json.dumps(self._normalize_rag_config(config))
        await session.commit()

  async def get_workspace_default_model_id(self, workspace_id: int) -> Optional[str]:
    """Return the workspace's default model id for new threads.

    NULL / "default" means "use the first available model config"; the UI
    resolves that fallback.
    """
    if not workspace_id:
      return None
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      return ws.default_model_id if ws else None

  async def set_workspace_default_model_id(self, workspace_id: int, model_id: Optional[str]) -> None:
    """Persist the workspace's default model id for new threads."""
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      if ws:
        ws.default_model_id = model_id or None
        await session.commit()

  async def get_workspace_tools_config(self, workspace_id: int) -> dict:
    """Return the persisted tools_config for a workspace ({} if unset)."""
    if not workspace_id:
      return {}
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      return self._parse_json_config(ws.tools_config) if ws else {}

  async def set_workspace_tools_config(self, workspace_id: int, config: dict) -> None:
    """Persist the tools_config for a workspace."""
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      if ws:
        ws.tools_config = json.dumps(config)
        await session.commit()

  async def get_workspace_skills_config(self, workspace_id: int) -> dict:
    """Return the persisted skills_config for a workspace ({} if unset)."""
    if not workspace_id:
      return {}
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      return self._parse_json_config(ws.skills_config) if ws else {}

  async def set_workspace_skills_config(self, workspace_id: int, config: dict) -> None:
    """Persist the skills_config for a workspace."""
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      if ws:
        ws.skills_config = json.dumps(config)
        await session.commit()

  async def get_thread_tools_config(self, thread_id: int) -> Optional[dict]:
    """Return the thread tools_config override, or None when it inherits the workspace."""
    if not thread_id:
      return None
    async with self.db.get_session() as session:
      th = await session.get(Thread, thread_id)
      if th and th.tools_config:
        return self._parse_json_config(th.tools_config)
      return None

  async def set_thread_tools_config(self, thread_id: int, config: dict) -> None:
    """Persist a thread-level tools_config override."""
    async with self.db.get_session() as session:
      th = await session.get(Thread, thread_id)
      if th:
        th.tools_config = json.dumps(config)
        await session.commit()

  async def get_thread_skills_config(self, thread_id: int) -> Optional[dict]:
    """Return the thread skills_config override, or None when it inherits the workspace."""
    if not thread_id:
      return None
    async with self.db.get_session() as session:
      th = await session.get(Thread, thread_id)
      if th and th.skills_config:
        return self._parse_json_config(th.skills_config)
      return None

  async def set_thread_skills_config(self, thread_id: int, config: dict) -> None:
    """Persist a thread-level skills_config override."""
    async with self.db.get_session() as session:
      th = await session.get(Thread, thread_id)
      if th:
        th.skills_config = json.dumps(config)
        await session.commit()

  async def resolve_tools_config(
    self, workspace_id: Optional[int], thread_id: Optional[int]
  ) -> dict:
    """
    Return the effective tools_config: the thread override when present,
    otherwise the workspace defaults ({} when neither is configured, which
    the registry treats as "all tools enabled").
    """
    if thread_id:
      tcfg = await self.get_thread_tools_config(thread_id)
      if tcfg is not None:
        return tcfg
    if workspace_id:
      return await self.get_workspace_tools_config(workspace_id)
    return {}

  async def resolve_skills_config(
    self, workspace_id: Optional[int], thread_id: Optional[int]
  ) -> dict:
    """Return the effective skills_config (thread override else workspace)."""
    if thread_id:
      scfg = await self.get_thread_skills_config(thread_id)
      if scfg is not None:
        return scfg
    if workspace_id:
      return await self.get_workspace_skills_config(workspace_id)
    return {}

  # ---------------------------------------------------------------------
  # HITL tool-approval policy (per workspace / thread)
  # ---------------------------------------------------------------------

  # Default policy: require approval for both queries and mutations.
  _DEFAULT_APPROVAL_CONFIG = {"query": True, "mutation": True}

  @classmethod
  def _normalize_approval_config(cls, cfg: Optional[dict]) -> dict:
    """Coerce a (possibly partial/invalid) config to a full {query, mutation} dict."""
    base = dict(cls._DEFAULT_APPROVAL_CONFIG)
    if isinstance(cfg, dict):
      for key in ("query", "mutation"):
        if key in cfg:
          base[key] = bool(cfg[key])
    return base

  async def get_workspace_approval_config(self, workspace_id: int) -> dict:
    """Return the workspace's approval policy (defaults when unset)."""
    if not workspace_id:
      return dict(self._DEFAULT_APPROVAL_CONFIG)
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      raw = self._parse_json_config(ws.approval_config) if ws else {}
    return self._normalize_approval_config(raw)

  async def set_workspace_approval_config(self, workspace_id: int, config: dict) -> None:
    """Persist the approval policy for a workspace."""
    async with self.db.get_session() as session:
      ws = await session.get(Workspace, workspace_id)
      if ws:
        ws.approval_config = json.dumps(self._normalize_approval_config(config))
        await session.commit()

  async def get_thread_approval_config(self, thread_id: int) -> Optional[dict]:
    """Return the thread's approval override, or None when it inherits the workspace."""
    if not thread_id:
      return None
    async with self.db.get_session() as session:
      th = await session.get(Thread, thread_id)
      if th and th.approval_config:
        return self._normalize_approval_config(self._parse_json_config(th.approval_config))
    return None

  async def set_thread_approval_config(self, thread_id: int, config: dict) -> None:
    """Persist a thread-level approval override."""
    async with self.db.get_session() as session:
      th = await session.get(Thread, thread_id)
      if th:
        th.approval_config = json.dumps(self._normalize_approval_config(config))
        await session.commit()

  async def resolve_approval_config(
    self, workspace_id: Optional[int], thread_id: Optional[int]
  ) -> dict:
    """Effective approval policy: thread override else workspace else default (all True)."""
    if thread_id:
      cfg = await self.get_thread_approval_config(thread_id)
      if cfg is not None:
        return cfg
    if workspace_id:
      return await self.get_workspace_approval_config(workspace_id)
    return dict(self._DEFAULT_APPROVAL_CONFIG)

  # ---------------------------------------------------------------------
  # HITL approval request/response bridge
  # ---------------------------------------------------------------------

  async def _await_approval(self, tool_call_id: str) -> bool:
    """ Suspend until the UI resolves the approval for *tool_call_id* """
    if tool_call_id in self._approval_inbox:
      return self._approval_inbox.pop(tool_call_id)
    loop = asyncio.get_running_loop()
    fut: asyncio.Future = loop.create_future()
    self._pending_approvals[tool_call_id] = fut
    try:
      return await fut
    finally:
      self._pending_approvals.pop(tool_call_id, None)
      self._approval_inbox.pop(tool_call_id, None)

  def resolve_approval(self, tool_call_id: str, approved: bool) -> bool:
    """ Resolve a pending tool-approval request from the UI """
    fut = self._pending_approvals.get(tool_call_id)
    if fut is not None and not fut.done():
      fut.set_result(bool(approved))
      return True
    self._approval_inbox[tool_call_id] = bool(approved)
    return True

  def cancel_pending_approvals(self) -> None:
    """Deny/cancel any outstanding approval requests (e.g. on thread switch)."""
    for tool_call_id, fut in list(self._pending_approvals.items()):
      if not fut.done():
        fut.set_result(False)
      self._pending_approvals.pop(tool_call_id, None)
    self._approval_inbox.clear()

  async def run_agent_stream(self, message: str):
    """ Legacy: Runs the agent in streaming mode (kept for TUI / API compatibility). """
    if not hasattr(self, 'agent') or not self.agent:
      raise ValueError("Agent not configured. Use 'set_model <provider> <model_name>' and ensures keys are set with 'add_key'.")
    async with self.agent.run_stream(message) as result:
      async for chunk in result.stream_output():
        yield chunk

  async def stop_engine(self):
    """ Cleanup engine resources """
    # Stop the periodic directory watcher.
    if self._watch_task is not None and not self._watch_task.done():
      self._watch_task.cancel()
      try:
        await self._watch_task
      except asyncio.CancelledError:
        pass

    # Signal any running index worker threads to stop between files so their
    # executor threads unwind promptly instead of hanging shutdown.
    for cancel in list(self._index_cancels.values()):
      cancel.set()

    # Stop the API service first so no new requests arrive during teardown.
    service = getattr(self, "api_service", None)
    if service is not None:
      try:
        await asyncio.wait_for(service.stop(), timeout=11.0)
      except asyncio.TimeoutError:
        logger.warning("Engine stop_engine: api_service.stop() timed out.")
    
    if hasattr(self, '_heartbeat_task') and not self._heartbeat_task.done():
      self._heartbeat_task.cancel()
      try:
        await self._heartbeat_task
      except asyncio.CancelledError:
        pass
    
    if hasattr(self, 'db'):
      try:
        await asyncio.wait_for(self.db.close(), timeout=1.0)
      except asyncio.TimeoutError:
        logger.warning("Engine stop_engine: db.close() timed out.")
    logger.debug("Engine stopped.")

  async def heartbeat(self):
    """ A simple heartbeat task to indicate the engine is still running normally """
    try:
      while True:
        logger.debug("heartbeat")
        await asyncio.sleep(60) #@IgnoreException
    except asyncio.CancelledError:
      pass
  
  async def show_notification(self, title: str, message: str) -> None:
    """ Display a notification to the user.
        Base implementation logs only — platform-specific engines (DesktopEngine,
        etc.) override this to send OS/push notifications.
    """
    logger.info(f"[notification] {title}: {message}")

  async def update_setting(self, key: str, value: str, tag: str = "system"):
    """ Update a setting in the database and notify any registered UI callbacks. """
    async with self.db.get_session() as session:
      insert_values = {
        "key": key,
        "tag": tag,
        "value": value
      }
      
      # Build the SQLite upsert statement
      stmt = (
        sqlite_insert(AppState)
        .values(**insert_values)
        .on_conflict_do_update(
          index_elements=[AppState.key, AppState.tag],
          set_={"value": sqlite_insert(AppState).excluded.value}
        )
      )
      
      # Execute and commit
      await session.execute(stmt)
      await session.commit()

    # Notify registered UI callbacks so changes are reflected in real-time
    for cb in self._setting_callbacks.get(key, []):
      try:
        await cb(key, value, tag)
      except Exception as exc:
        logger.warning(f"Setting callback error for key '{key}': {exc}")

  async def get_setting(self, key: str, tag: str = "system") -> Optional[str]:
    """Get a setting from the database."""
    async with self.db.get_session() as session:
      result = await session.scalar(
        select(AppState.value).where(
          AppState.key == key,
          AppState.tag == tag
        )
      )
      return result

  async def save_ui_state(self, key: str, value: str) -> None:
    """Upsert a UI state entry in app_state (tag='ui_state')."""
    async with self.db.get_session() as session:
      existing = await session.scalar(
        select(AppState).where(AppState.key == key, AppState.tag == "ui_state")
      )
      if existing:
        existing.value = value
      else:
        session.add(AppState(key=key, value=value, tag="ui_state"))
      await session.commit()

  async def load_ui_state(self) -> dict:
    """Load all UI state entries from app_state (tag='ui_state')."""
    async with self.db.get_session() as session:
      result = await session.scalars(
        select(AppState).where(AppState.tag == "ui_state")
      )
      return {s.key: s.value for s in result.all()}

  async def check_for_updates(self):
    """ Check for updates """
    try:
      async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get("https://api.github.com/repos/Ancilla-Company/Subconscious/releases/latest", headers={"User-Agent": f"Subconscious/{VERSION}"}) #@IgnoreException
        resp.raise_for_status() #@IgnoreException
        data = resp.json()
      
      latest_version = Version(data['tag_name'])
      current_version = Version(VERSION)

      if latest_version > current_version:
        self.update_available = True
        self.latest_version = str(latest_version)
      else:
        self.update_available = False
        self.latest_version = None
    except httpx.HTTPStatusError as e:
      logger.error(f"The server returned and error: {e}")
    except Exception as e:
      logger.debug(f"Error checking for updates: {e}")

  def _load_build_metadata(self) -> dict:
    metadata_path = pathlib.Path(__file__).parent / "assets" / "build_metadata.json"
    try:
      return json.loads(metadata_path.read_text(encoding="utf-8"))
    except Exception as e:
      logger.debug(f"Failed to load build metadata: {e}")
      return {}


  async def load_skill_configs(self) -> list[dict]:
    """Load all skill registry entries from the database."""
    async with self.db.get_session() as session:
      result = await session.scalars(select(SkillRegistry))
      rows = result.all()
      return [
        {
          "id": r.uuid,
          "alias": r.alias or "",
          "source": r.source,
          "source_type": r.source_type,
          "install_path": r.install_path or "",
          "status": r.status,
          "required_tools": r.required_tools or "",
          "version": r.version or "",
        }
        for r in rows
      ]

  async def save_skill_config(self, skill_dict: dict) -> dict:
    """
    Persist a skill entry, install/copy its package into data_dir/skills/<uuid>,
    validate by looking for a skill.json manifest, and return the updated dict
    with status and required_tools populated.
    """
    skill_uuid = skill_dict["id"]
    source = skill_dict.get("source", "").strip()
    source_type = skill_dict.get("source_type", "folder")
    alias = skill_dict.get("alias", "")

    skills_dir = self.config.data_dir / "skills"
    skills_dir.mkdir(parents=True, exist_ok=True)
    install_path = skills_dir / skill_uuid

    status = "pending"
    required_tools_json = ""
    version = ""

    async with self.db.get_session() as session:
      row = await session.scalar(
        select(SkillRegistry).where(SkillRegistry.uuid == skill_uuid)
      )
      if row:
        row.alias = alias
        row.source = source
        row.source_type = source_type
        row.install_path = str(install_path)
        row.status = status
        row.required_tools = required_tools_json
        row.version = version
      else:
        row = SkillRegistry(
          uuid=skill_uuid,
          name=alias or source.rstrip("/\\").split("/")[-1].split("\\")[-1] or skill_uuid,
          alias=alias,
          source=source,
          source_type=source_type,
          install_path=str(install_path),
          status=status,
          required_tools=required_tools_json,
          version=version,
        )
        session.add(row)
      await session.commit()

    return {**skill_dict, "status": status, "required_tools": required_tools_json, "version": version}

  async def delete_skill_config(self, skill_uuid: str) -> None:
    """Remove a skill from the registry and delete its installed package files."""
    async with self.db.get_session() as session:
      row = await session.scalar(
        select(SkillRegistry).where(SkillRegistry.uuid == skill_uuid)
      )
      if row:
        if row.install_path:
          ip = pathlib.Path(row.install_path)
          if ip.exists():
            shutil.rmtree(ip, ignore_errors=True)
        await session.delete(row)
        await session.commit()


  async def load_tool_configs(self) -> list[dict]:
    """Load all tool registry entries from the database."""
    async with self.db.get_session() as session:
      result = await session.scalars(select(ToolRegistryModel))
      rows = result.all()
      configs = []
      self.config.read_keyring()
      tool_keys = self.config.secrets.get("tools", {})
      for r in rows:
        configs.append({
          "id": r.uuid,
          "alias": r.alias or "",
          "tool_type": r.tool_type,
          "script_path": r.script_path or "",
          "script_language": r.script_language or "python",
          "endpoint_url": r.endpoint_url or "",
          "auth_type": r.auth_type or "",
          "auth_env_var": r.auth_env_var or "",
          # API key value is never stored in the DB — read from encrypted store
          "api_key": tool_keys.get(r.uuid, {}).get("api_key", ""),
          "status": r.status,
        })
      return configs

  async def save_tool_config(self, tool_dict: dict) -> None:
    """Persist a tool registry entry and store the API key in encrypted storage."""
    tool_uuid = tool_dict["id"]

    # Store API key encrypted in keyring store
    api_key = tool_dict.get("api_key", "").strip()
    if api_key:
      self.config.read_keyring()
      tool_keys = self.config.secrets.setdefault("tools", {})
      tool_keys[tool_uuid] = {"api_key": api_key}
      await self.config.write_keyring()
      # Also inject into environment immediately for the current session
      env_var = tool_dict.get("auth_env_var", "").strip()
      if env_var:
        os.environ[env_var] = api_key

    async with self.db.get_session() as session:
      row = await session.scalar(
        select(ToolRegistryModel).where(ToolRegistryModel.uuid == tool_uuid)
      )
      if row:
        row.alias = tool_dict.get("alias", "")
        row.tool_type = tool_dict.get("tool_type", "script")
        row.script_path = tool_dict.get("script_path", "")
        row.script_language = tool_dict.get("script_language", "python")
        row.endpoint_url = tool_dict.get("endpoint_url", "")
        row.auth_type = tool_dict.get("auth_type", "")
        row.auth_env_var = tool_dict.get("auth_env_var", "")
      else:
        alias = tool_dict.get("alias", "")
        row = ToolRegistryModel(
          uuid=tool_uuid,
          name=alias or tool_dict.get("tool_type", "tool"),
          alias=alias,
          tool_type=tool_dict.get("tool_type", "script"),
          script_path=tool_dict.get("script_path", ""),
          script_language=tool_dict.get("script_language", "python"),
          endpoint_url=tool_dict.get("endpoint_url", ""),
          auth_type=tool_dict.get("auth_type", ""),
          auth_env_var=tool_dict.get("auth_env_var", ""),
        )
        session.add(row)
      await session.commit()

  async def delete_tool_config(self, tool_uuid: str) -> None:
    """Remove a tool from the registry and its encrypted key."""
    self.config.read_keyring()
    self.config.secrets.get("tools", {}).pop(tool_uuid, None)
    await self.config.write_keyring()

    async with self.db.get_session() as session:
      row = await session.scalar(
        select(ToolRegistryModel).where(ToolRegistryModel.uuid == tool_uuid)
      )
      if row:
        await session.delete(row)
        await session.commit()

  async def run_update(self):
    metadata = self._load_build_metadata()
    package_method = metadata.get("package_method")
    # For pip: the PyPI distribution name (e.g. "subconscious")
    # For winget: the package ID (e.g. "Ancilla.Subconscious")
    # For apt-get: the apt package name (e.g. "subconscious")
    package_name = metadata.get("package_name", "Subconscious-Chat")

    command_map = {
      # Pin to the exact version detected by check_for_updates; fall back to --upgrade if unknown
      "python": (
        [sys.executable, "-m", "pip", "install", f"{package_name}=={self.latest_version}"]
        if self.latest_version else
        [sys.executable, "-m", "pip", "install", "--upgrade", package_name]
      ),
      # winget requires --id for exact package identifier matching
      "winget": ["winget", "upgrade", "--id", package_name, "--silent"],
      # apt-get install --only-upgrade upgrades only if already installed
      "apt-get": ["sudo", "apt-get", "install", "--only-upgrade", "-y", package_name],
    }

    command = command_map.get(package_method)
    if not command:
      raise ValueError(f"Unsupported or missing package_method in build metadata: {package_method!r}")

    if getattr(self.config, 'dev', False):
      logger.info("[dev] Would run update command: %s", " ".join(command))
      print(f"[dev] run_update called — skipping real update.\n  method : {package_method}\n  package: {package_name}\n  command: {' '.join(command)}")
      return

    logger.info("Running update command: %s", " ".join(command))
    process = await asyncio.create_subprocess_exec(*command)
    return_code = await process.wait()

    if return_code == 0:
      logger.info("Update completed successfully.")
      await self.show_notification("Subconscious", "Update installed. Please restart the app.")
    else:
      logger.error("Update command exited with code %d", return_code)
      await self.show_notification("Subconscious", f"Update failed (exit code {return_code}). Check logs for details.")
