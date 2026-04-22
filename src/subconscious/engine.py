import os
import re
import sys
import uuid
import json
import httpx
import shutil
import zipfile
import asyncio
import logging
import pathlib
import docx as _docx
import pypdf as _pypdf
import openpyxl as _openpyxl
from datetime import datetime
from sqlalchemy import select
from packaging.version import Version
from typing import AsyncIterator, Optional
from sqlalchemy import update as sql_update
from desktop_notifier import DesktopNotifier, Icon
from pydantic_ai.messages import (
  ModelMessage, ModelRequest, ModelResponse,
  UserPromptPart, TextPart,
)

from .config import Config
from .constants import VERSION
from .agent import AgentManager
from .db.session import Database
from .tools import ToolRegistry, EngineContext
from .db.models import (
  Workspace, Thread, Message, AppState, Networks,
  SkillRegistry, ToolRegistry as ToolRegistryModel,
)


_icon_path = pathlib.Path(__file__).parent / "assets" / "icon_sm.png"
notifier = DesktopNotifier(
  app_name="Subconscious",
  app_icon=Icon(path=_icon_path),
)

# Logging setup
logger = logging.getLogger("subconscious")


class Engine:
  """ Subconscious Engine Core """
  update_available = None

  async def init_settings(self):
    """ Initialize settings from settings.json to AppState if not present """
    try:
      system_settings = {
        "mode": [ "auto", "light", "dark" ],
        "language": [ "en" ],
        "position": [ "x", "y" ],
        "size": [ "width", "height" ],
        "maximized": [ False, True ]
      }
      
      async with self.db.get_session() as session:
        for key, value in system_settings.items():
          # Check if already in DB
          exists = await session.scalar(
            select(AppState).where(AppState.key == key, AppState.tag == "system")
          )
          
          if not exists:
            default_value = value[0]
            new_setting = AppState(key=key, value=str(default_value), tag="system")
            session.add(new_setting)
            logger.debug(f"Initialized system setting: {key}={default_value}")
        
        await session.commit()
    except Exception as e:
      logger.error(f"Failed to initialize settings: {e}")

  async def init_system(self):
    """ Initialize system components (DB, Default Workspace) """
    await self.db.init_models()
    await self.init_settings()

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
    # Initialize Database
    self.config = config
    self.config.load()
    self.db = Database(config)
    await self.init_system()

    # Check for updates
    asyncio.create_task(self.check_for_updates())

    # start the heartbeat: DEBUG
    self._heartbeat_task = asyncio.create_task(self.heartbeat())

    # Initialize Agent Manager
    self.agent_manager = AgentManager(config)

    # Initialize Tool Registry
    self.tool_registry = ToolRegistry()

    # Show ready notification: DEBUG
    await self.show_notification("Subconscious", "Startup Complete.")

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
    Stream an AI response for *content* given the existing thread history.
    Yields text chunks as they arrive from the LLM.

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
    slugs = enabled_tools if enabled_tools is not None else self.tool_registry.all_slugs()
    tools = self.tool_registry.get_tools(slugs)

    agent = self.agent_manager.build_agent(model_cfg, tools=tools)  # type: ignore[call-arg]

    # Build the dependency context for tools that need DB / workspace access
    ctx_deps = EngineContext(
      db=self.db,
      workspace_id=workspace_id or 0,
      thread_id=thread_id,
      data_dir=str(self.config.data_dir),
    )

    # Build an attachment context block and prepend it to the user prompt
    prompt = self._build_prompt_with_attachments(content, attachments or [])

    async with agent.run_stream(prompt, message_history=history, deps=ctx_deps) as result:  # type: ignore[call-overload]
      async for chunk in result.stream_text(delta=True):
        yield chunk

  def _build_prompt_with_attachments(self, content: str, attachments: list[dict]) -> str:
    """
    Given a list of attachment dicts (each with 'path', 'type', 'name') build a
    context preamble that inlines file contents or directory listings using a
    tiered strategy based on file size:

      < 2 MB   — Full load: entire file text is inlined.
      2–10 MB  — Skeleton: structural lines + first/last 20 lines are inlined;
                 the model should use read_range() for targeted access.
      > 10 MB  — RAG hint: only metadata is inlined; the model should use
                 search_in_file() then read_range() to access content.

    Directories are always listed one level deep.
    The original user message is appended at the end.
    """
    _FULL_LIMIT    =  2_000_000   #  2 MB
    _CHUNKED_LIMIT = 10_000_000   # 10 MB

    if not attachments:
      return content

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

          if char_count <= _FULL_LIMIT:
            sections.append(f"### File: {name}\n```\n{text}\n```")

          elif char_count <= _CHUNKED_LIMIT:
            # Skeleton: structural lines + head + tail
            lines = text.splitlines()
            total = len(lines)
            if ext == ".py":
              pat = _re.compile(r"^\s*(class |def |async def |@|\bimport |\bfrom )")
            elif ext in (".md", ".markdown", ".rst"):
              pat = _re.compile(r"^(#{1,6} |={3,}|-{3,})")
            else:
              pat = _re.compile(r"^\s*(class |def |function |public |private |export |import |from )")

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
            sections.append(f"### File: {name}\n{body}")

          else:
            sections.append(
              f"### File: {name}\n"
              f"[RAG MODE — file is {size_bytes:,} bytes (> 10 MB). "
              f"Use search_in_file(path='{path}', query='...') to find relevant lines, "
              f"then read_range(path='{path}', start_line=N, end_line=M) to read them.]"
            )

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

  async def run_agent_stream(self, message: str):
    """ Legacy: Runs the agent in streaming mode (kept for TUI / API compatibility). """
    if not hasattr(self, 'agent') or not self.agent:
      raise ValueError("Agent not configured. Use 'set_model <provider> <model_name>' and ensures keys are set with 'add_key'.")
    async with self.agent.run_stream(message) as result:
      async for chunk in result.stream_output():
        yield chunk

  async def stop_engine(self):
    """ Cleanup engine resources """
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
  
  async def show_notification(self, title, message):
    try:
      await notifier.send(
        title=title,
        message=message
      )
    except Exception as e:
      print(f"Notification error: {e}")

  async def update_setting(self, key: str, value: str, tag: str = "system"):
    """Update a setting in the database."""
    async with self.db.get_session() as session:
      stmt = sql_update(AppState).where(
        AppState.key == key,
        AppState.tag == tag
      ).values(value=value)
      await session.execute(stmt)
      await session.commit()
      logger.debug(f"Updated setting: {key}={value} (tag={tag})")

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
      else:
        self.update_available = False
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

    # try:
    #   if source_type == "folder":
    #     src = pathlib.Path(source)
    #     if not (src.exists() and src.is_dir()):
    #       raise FileNotFoundError(f"Folder not found: {source}")
    #     if install_path.exists():
    #       shutil.rmtree(install_path)
    #     shutil.copytree(src, install_path)

    #   elif source_type == "zip":
    #     src = pathlib.Path(source)
    #     if not (src.exists() and src.suffix == ".zip"):
    #       raise FileNotFoundError(f"Zip not found: {source}")
    #     if install_path.exists():
    #       shutil.rmtree(install_path)
    #     install_path.mkdir(parents=True, exist_ok=True)
    #     with zipfile.ZipFile(src, "r") as zf:
    #       zf.extractall(install_path)

    #   elif source_type == "url":
    #     if install_path.exists():
    #       shutil.rmtree(install_path)
    #     install_path.mkdir(parents=True, exist_ok=True)
    #     zip_dest = install_path / "download.zip"
    #     async with httpx.AsyncClient(timeout=60, follow_redirects=True) as client:
    #       resp = await client.get(source)
    #       resp.raise_for_status()
    #       zip_dest.write_bytes(resp.content)
    #     with zipfile.ZipFile(zip_dest, "r") as zf:
    #       zf.extractall(install_path)
    #     zip_dest.unlink(missing_ok=True)

    #   else:
    #     raise ValueError(f"Unknown source_type: {source_type}")

    #   # Validate: look for skill.json manifest
    #   manifest_candidates = list(install_path.rglob("skill.json"))
    #   if manifest_candidates:
    #     manifest = json.loads(manifest_candidates[0].read_text(encoding="utf-8"))
    #     required_tools_json = json.dumps(manifest.get("required_tools", []))
    #     version = manifest.get("version", "")
    #     status = "valid"
    #   else:
    #     # Fallback: any directory with Python files is accepted as a basic skill
    #     py_files = list(install_path.rglob("*.py"))
    #     status = "valid" if py_files else "invalid"

    # except Exception as exc:
    #   logger.error(f"Skill install error for {skill_uuid}: {exc}")
    #   status = "error"

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
    package_name = metadata.get("package_name", "Subconscious")

    command_map = {
      # pip upgrades by distribution name
      "python": [sys.executable, "-m", "pip", "install", "--upgrade", package_name],
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
