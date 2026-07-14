""" Desktop version of Subconscious skeleton - desktop layout with titlebar & contextlist """
import json
import uuid
import asyncio
import pathlib
import logging
import traceback
import flet as ft
from sqlalchemy import select, func
from datetime import datetime, timezone

from .tray import *
from .frame import Frame
from .sidebar import Sidebar
from .titlebar import TitleBar
from .mainwindow import MainWindow
from .contextlist import ContextList
from .engine import DesktopEngine as Engine
from ..stream_events import tool_block_to_json
from ..db.models import Workspace, Thread, AppState
from ..shared.tool_config import ToolToggleTree, SkillToggleList
from ..shared.messages import HumanMessage, AIMessage, ToolMessage, ApprovalMessage
from ..stream_events import TextDelta, ToolCallStarted, ToolCallResult, ApprovalRequest, ApprovalResolved


# Logging config
logger = logging.getLogger("subconscious")


def _db_message_to_ui(role: str, content: str, ts):
  """Map a persisted message row (user / assistant / tool) to its UI bubble."""
  if role == "user":
    return HumanMessage(content=content, timestamp=ts)
  if role == "tool":
    return ToolMessage(content=content, timestamp=ts)
  return AIMessage(content=content, timestamp=ts)


@ft.component
def splash_screen(self):
  """ Show the splash screen """
  return ft.Container(
    content=ft.Row([
      ft.Column([
        ft.Image(src="/logo.png", width=100, height=100, color=ft.Colors.PRIMARY),
        ft.Text("Subconscious", size=25, color=ft.Colors.PRIMARY),
      ], alignment="center", horizontal_alignment="center", spacing=0, expand=True),
    ], alignment="center", vertical_alignment="center", spacing=0, expand=True),
    bgcolor=ft.Colors.SURFACE
  )


@ft.component
def AppView(page: ft.Page, engine) -> list[ft.Control]:
  """ Main application view - manages layout and global state """
  # TODO: Maybe splash screen can go here while engine is loading, then switch to main view once ready
  # Perhaps log the config to the splash screen

  # Layout state
  context_width, set_context_width = ft.use_state(380)
  current_view, set_current_view = ft.use_state("none")
  context_visible, set_context_visible = ft.use_state(False)
  current_context, set_current_context = ft.use_state("none")
  
  # Workspace Management State
  workspaces, set_workspaces = ft.use_state(list())
  editing_workspace, set_editing_workspace = ft.use_state(None) # For the "Workspaces" view
  active_chat_workspace, set_active_chat_workspace = ft.use_state(None) # For the "Threads" view
  workspace_mode, set_workspace_mode = ft.use_state("view") # view, create, edit
  
  # Thread Management State
  threads, set_threads = ft.use_state(list())
  selected_thread, set_selected_thread = ft.use_state(None)
  messages, set_messages = ft.use_state(list())
  is_streaming, set_is_streaming = ft.use_state(False)
  # Mutable ref holder for the chat ListView so we can call scroll_to() imperatively.
  # Stored as a single-element list so mutations don't trigger re-renders.
  chat_scroll_ref, _ = ft.use_state([None])

  def on_list_mounted(list_view):
    """Called by ChatWindow each render to keep our ref up-to-date."""
    chat_scroll_ref[0] = list_view

  # Holds the live streaming text for the current AI response so each token
  # triggers a guaranteed re-render via a dedicated scalar state change.
  streaming_text, set_streaming_text = ft.use_state("")
  # Persists the last-selected thread per workspace so it's restored on switch-back
  thread_by_workspace, set_thread_by_workspace = ft.use_state(dict())
  # When True the threads list shows threads across all workspaces
  show_all_threads, set_show_all_threads = ft.use_state(False)
  # Currently active model config for the chat window
  selected_model_config, set_selected_model_config = ft.use_state(None)

  # Settings Management State
  settings, set_settings = ft.use_state({})
  # Mutable ref to hold current settings for callbacks (avoids stale closure)
  settings_ref, _ = ft.use_state([{}])
  selected_setting, set_selected_setting = ft.use_state(None)
  about_badge_dismissed, set_about_badge_dismissed = ft.use_state(False)
  settings_badge_dismissed, set_settings_badge_dismissed = ft.use_state(False)
  # Model configs loaded from encrypted storage: list of dicts
  model_configs, set_model_configs = ft.use_state([])
  # Expanded panel indices for the model settings list - persisted across navigation
  model_expanded_indices, set_model_expanded_indices = ft.use_state(set())

  # Skill configs loaded from DB: list of dicts
  skill_configs, set_skill_configs = ft.use_state([])
  skill_expanded_indices, set_skill_expanded_indices = ft.use_state(set())

  # Tool configs loaded from DB: list of dicts
  tool_configs, set_tool_configs = ft.use_state([])
  tool_expanded_indices, set_tool_expanded_indices = ft.use_state(set())

  # Built-in tool hierarchy {slug: [{name, doc}]} loaded from the engine registry
  tool_catalog, set_tool_catalog = ft.use_state({})
  # Tools/Skills enable-disable config for the workspace currently being edited
  ws_tools_config, set_ws_tools_config = ft.use_state({})
  ws_skills_config, set_ws_skills_config = ft.use_state({})
  # HITL approval policy for the workspace currently being edited
  ws_approval_config, set_ws_approval_config = ft.use_state({})
  # Directories attached to the workspace currently being edited
  ws_directories, set_ws_directories = ft.use_state(list())
  # Thread-level Tools/Skills dialog: mode is None | "tools" | "skills".
  # Rendered declaratively in the reactive tree (see AppView return) so the
  # toggle components run inside the renderer context.
  thread_dialog_mode, set_thread_dialog_mode = ft.use_state(None)
  thread_dialog_cfg, set_thread_dialog_cfg = ft.use_state({})
  # Thread-level approval policy shown alongside the tools dialog.
  thread_dialog_approval_cfg, set_thread_dialog_approval_cfg = ft.use_state({})

  # Background jobs / notifications popup state
  notifications_open, set_notifications_open = ft.use_state(False)
  jobs, set_jobs = ft.use_state(list())

  # Chatbox initial values restored from DB on startup
  initial_chatbox_text, set_initial_chatbox_text = ft.use_state("")
  initial_chatbox_attachments, set_initial_chatbox_attachments = ft.use_state([])
  # Incremented every time we navigate to the threads view so ChatWindow's
  # use_effect always re-fires and seeds the chatbox from persisted state.
  chatbox_restore_token, set_chatbox_restore_token = ft.use_state(0)
  # Mutable refs for debounced async tasks (single-element lists avoid re-renders)
  _resize_debounce = [None]
  _chatbox_debounce = [None]

  _MODE_MAP = {
    "light": ft.ThemeMode.LIGHT,
    "dark": ft.ThemeMode.DARK,
    "auto": ft.ThemeMode.SYSTEM,
  }

  _LIGHT = ft.Theme(
    color_scheme=ft.ColorScheme(
      primary=ft.Colors.BLACK,
      secondary=ft.Colors.GREY,
      surface=ft.Colors.WHITE,
      secondary_container=ft.Colors.GREY_300,
      primary_container=ft.Colors.GREY_300
    )
  )
  _DARK = ft.Theme(
    color_scheme=ft.ColorScheme(
      primary=ft.Colors.WHITE,
      secondary=ft.Colors.GREY,
      surface=ft.Colors.BLACK87,
      secondary_container=ft.Colors.GREY_800,
      primary_container=ft.Colors.GREY_800
    )
  )

  _THEME_MAP = {
    "purple": ft.Theme(color_scheme_seed=ft.Colors.DEEP_PURPLE),
    "blue": ft.Theme(color_scheme_seed=ft.Colors.BLUE),
    "teal": ft.Theme(color_scheme_seed=ft.Colors.TEAL),
    "green": ft.Theme(color_scheme_seed=ft.Colors.GREEN),
    "yellow": ft.Theme(color_scheme_seed=ft.Colors.YELLOW),
    "orange": ft.Theme(color_scheme_seed=ft.Colors.ORANGE),
    "red": ft.Theme(color_scheme_seed=ft.Colors.RED),
    "pink": ft.Theme(color_scheme_seed=ft.Colors.PINK),
  }

  async def apply_setting_to_ui(key: str, value: str, _tag: str = "system"):
    """
    UI-only: apply an already-persisted setting to the live Flet page and
    local state.  Called by the engine callback registry when a tool (or any
    other non-UI code) changes a setting so the change is visible immediately
    without a restart.
    """
    if key == "mode":
      page.theme_mode = _MODE_MAP.get(value, ft.ThemeMode.SYSTEM)
      page.update()
    elif key == "colour":
      if value == "default":
        page.theme = _LIGHT
        page.dark_theme = _DARK
      else:
        page.theme = _THEME_MAP.get(value, page.theme)
        page.dark_theme = _THEME_MAP.get(value, page.theme)
      page.update()

    new_settings = {**settings_ref[0], key: str(value)}
    settings_ref[0] = new_settings
    set_settings(new_settings)

  def build_model_configs() -> list:
    """Read model configs fresh from encrypted storage (plus the dev echo agent).

    Used both for the initial load and for restoring a thread's persisted model
    on startup / workspace switch, where the reactive `model_configs` closure
    may not be populated yet.
    """
    engine.config.read_keyring()
    raw_models = engine.config.secrets.get("models", {})
    loaded = [{"id": k, **v} for k, v in raw_models.items()]
    # In dev mode, append a simple echo agent for fast testing
    if engine.config.dev:
      loaded.append(
        {
          'id': 'echo',
          'provider': 'Subconscious',
          'model': 'echo',
          'api_key': '',
          'alias': 'Subconscious:Echo'
        }
      )
    return loaded

  async def resolve_thread_model(thread_id, configs=None):
    """Map a thread's persisted model id to a config dict.

    A stored value of 'default'/NULL — or an id pointing at a since-deleted
    model — falls back to the first available config so the selector is never
    left empty. Pass `configs` to reuse an already-loaded list; otherwise the
    configs are read fresh from storage (needed during startup restore).
    """
    cfgs = configs if configs else build_model_configs()
    if not cfgs:
      return None
    db_model_id = await engine.get_thread_model_id(thread_id)
    if db_model_id and db_model_id != "default":
      match = next((c for c in cfgs if c.get("id") == db_model_id), None)
      if match:
        return match
    return cfgs[0]

  async def load_settings():
    # Register the UI-only callback so tool-driven setting changes are
    # reflected in real-time.  We do NOT register handle_setting_change here
    # because that function also calls engine.update_setting, which would
    # trigger the callback again and cause infinite recursion.
    engine.register_setting_callback("mode", apply_setting_to_ui)
    engine.register_setting_callback("colour", apply_setting_to_ui)

    async with engine.db.get_session() as session:
      stmt = select(AppState).where(AppState.tag.in_(["system", "general"]))
      result = await session.scalars(stmt)
      db_settings = {s.key: s.value for s in result.all()}
      settings_ref[0] = db_settings
      set_settings(db_settings)

      # Apply some settings immediately if needed
      if "mode" in db_settings:
        await apply_setting_to_ui("mode", db_settings["mode"], "system")
        # page.theme_mode = _MODE_MAP.get(db_settings["mode"], ft.ThemeMode.SYSTEM)
      if "colour" in db_settings:
        await apply_setting_to_ui("colour", db_settings["colour"], "system")
      

    # Load model configs from encrypted storage
    loaded = build_model_configs()

    set_model_configs(loaded)

    # Default to the first model config if none is currently selected
    if loaded and selected_model_config is None:
      set_selected_model_config(loaded[0])

    # Load skill and tool configs from DB
    loaded_skills = await engine.load_skill_configs()
    set_skill_configs(loaded_skills)
    loaded_tools = await engine.load_tool_configs()
    set_tool_configs(loaded_tools)

    # Load the built-in tool hierarchy for the toggle trees
    try:
      set_tool_catalog(engine.get_tool_catalog())
    except Exception as exc:
      logger.warning(f"Failed to load tool catalog: {exc}")

  async def restore_ui_state():
    """Load persisted UI state from app_state and restore view, workspace, thread, and chatbox."""
    try:
      ui = await engine.load_ui_state()
    except Exception:
      return

    # --- Window size ---
    async def resizer():
      try:
        # await asyncio.sleep(2)
        w = ui.get("ui_window_width", 800.0)
        h = ui.get("ui_window_height", 800.0)
        if w:
          page.window.width = float(w)
        if h:
          page.window.height = float(h)
        if w or h:
          page.update()
      except Exception as e:
        pass
    asyncio.create_task(resizer())

    # --- Navigation ---
    view = ui.get("ui_current_view", "none")
    ctx = ui.get("ui_current_context", "none")
    account = ui.get("ui_current_account", "none")
    workspace = ui.get("ui_selected_workspace_id")
    setting = ui.get("ui_selected_setting") or None
    ctx_vis = ui.get("ui_context_visible", "false") == "true"

    # Defer set_current_view until after chatbox state is ready (see bottom of this function).
    # Setting the view to "threads" before initial_chatbox_text is set causes ChatWindow to
    # mount with empty props, defeating the key-based remount restore strategy.
    set_current_context(ctx)
    set_context_visible(ctx_vis)

    # --- Selected setting ---
    if setting:
      set_selected_setting(setting)

    # --- Selected workspace ---
    if workspace:
      async with engine.db.get_session() as session:
        workspace_obj = await session.get(Workspace, int(workspace))

        if workspace_obj:
          set_workspace_mode("edit")
          set_editing_workspace(workspace_obj)
          set_ws_tools_config(Engine._parse_json_config(getattr(workspace_obj, "tools_config", None)))
          set_ws_skills_config(Engine._parse_json_config(getattr(workspace_obj, "skills_config", None)))
          set_ws_approval_config(Engine._parse_json_config(getattr(workspace_obj, "approval_config", None)))
          set_ws_directories(Engine._parse_json_list(getattr(workspace_obj, "directories", None)))
    
    # --- Selected account ---

    # --- All-workspaces threads view ---
    # Restore this before the active workspace so the on_workspace_change effect
    # loads the correct (all-workspaces) thread list rather than a single workspace.
    show_all = ui.get("ui_show_all_threads", "false") == "true"
    if show_all:
      set_show_all_threads(True)

    # --- Active workspace ---
    ws_id_str = ui.get("ui_active_workspace_id", "")
    restored_ws = None
    if ws_id_str:
      try:
        ws_id = int(ws_id_str)
        async with engine.db.get_session() as session:
          restored_ws = await session.get(Workspace, ws_id)
        if restored_ws:
          set_active_chat_workspace(restored_ws)
      except Exception:
        pass

    # --- Active thread ---
    thread_id_str = ui.get("ui_selected_thread_id", "")
    if thread_id_str:
      try:
        thread_id = int(thread_id_str)
        async with engine.db.get_session() as session:
          restored_thread = await session.get(Thread, thread_id)
        if restored_thread:
          set_selected_thread(restored_thread)
          await load_messages(thread_id)

          # Restore the thread's persisted model so the selection survives restarts
          set_selected_model_config(await resolve_thread_model(thread_id))

          # Also record which thread belongs to the restored workspace
          ws_key = restored_ws.id if restored_ws else None
          set_thread_by_workspace({ws_key: restored_thread})
      except Exception:
        pass

    # --- Chatbox ---
    chatbox_text = ui.get("ui_chatbox_text", "")
    try:
      chatbox_attachments = json.loads(ui.get("ui_chatbox_attachments", "[]"))
    except Exception:
      chatbox_attachments = []
    set_initial_chatbox_text(chatbox_text)
    set_initial_chatbox_attachments(chatbox_attachments)
    # Set the view and bump the token together so ChatWindow first mounts (or remounts)
    # with the correct initial_chatbox_text/attachments already in props.
    set_current_view(view)
    set_chatbox_restore_token(chatbox_restore_token + 1)

  def handle_chatbox_change(text: str, attachments: list):
    """ Debounced save of chatbox text and attachments to app_state. """
    # Cancel any pending save
    if _chatbox_debounce[0] and not _chatbox_debounce[0].done():
      _chatbox_debounce[0].cancel()

    attachments_json = json.dumps(attachments)

    if not text and not attachments:
      # Clear immediately so a sent/cleared chatbox is never falsely restored
      async def immediate_clear():
        set_initial_chatbox_text("")
        set_initial_chatbox_attachments(attachments)
        await engine.save_ui_state("ui_chatbox_text", "")
        await engine.save_ui_state("ui_chatbox_attachments", "[]")
      _chatbox_debounce[0] = asyncio.create_task(immediate_clear())
      return

    async def delayed_save(): #@IgnoreException
      await asyncio.sleep(1.5)
      set_initial_chatbox_text(text)
      set_initial_chatbox_attachments(attachments)
      await engine.save_ui_state("ui_chatbox_text", text)
      await engine.save_ui_state("ui_chatbox_attachments", attachments_json)

    _chatbox_debounce[0] = asyncio.create_task(delayed_save())

  def handle_window_event(e: ft.WindowEvent):
    """ On window resize store dimensions """
    async def save_size(e: ft.WindowEvent):
      await asyncio.sleep(1.5)
      await engine.save_ui_state("ui_window_width", str(e.control.width))
      await engine.save_ui_state("ui_window_height", str(e.control.height))

    if e.type.name == "RESIZED":
      # Cancel any pending save
      if _resize_debounce[0] and not _resize_debounce[0].done():
        _resize_debounce[0].cancel()
      
      _resize_debounce[0] = asyncio.create_task(save_size(e))

  async def handle_setting_change(key, value, tag):
    """UI-driven: persist a setting to the database then apply it to the UI."""
    await engine.update_setting(key, str(value), tag)
    # engine.update_setting fires apply_setting_to_ui via the callback registry,
    # so we do NOT call apply_setting_to_ui manually here to avoid double-updates.

  async def handle_save_model(model_dict: dict):
    """Persist a model config (add or update) to the encrypted secrets file."""
    engine.config.read_keyring()
    models_store = engine.config.secrets.get("models", {})
    model_id = model_dict["id"]
    # Store only the real fields (strip the internal id key)
    _ui_keys = {"id"}
    models_store[model_id] = {k: v for k, v in model_dict.items() if k not in _ui_keys}
    engine.config.secrets["models"] = models_store
    await engine.config.write_keyring()
    # Refresh local state
    loaded = [{"id": k, **v} for k, v in models_store.items()]
    set_model_configs(loaded)

  def handle_delete_model(model_id: str, on_confirmed=None):
    """Show a confirmation dialog then delete the model config from encrypted storage."""
    def close_dlg(e):
      dlg.open = False
      page.update()

    async def do_delete(e):
      engine.config.read_keyring()
      models_store = engine.config.secrets.get("models", {})
      models_store.pop(model_id, None)
      engine.config.secrets["models"] = models_store
      await engine.config.write_keyring()
      loaded = [{"id": k, **v} for k, v in models_store.items()]
      set_model_configs(loaded)
      if on_confirmed:
        on_confirmed()
      close_dlg(e)

    dlg = ft.AlertDialog(
      modal=True,
      title=ft.Text("Delete Model"),
      content=ft.Text("Are you sure you want to delete this model configuration?"),
      actions=[
        ft.TextButton(
          "Delete", on_click=do_delete,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3))
        ),
        ft.TextButton(
          "Cancel", on_click=close_dlg,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3))
        ),
      ],
      actions_alignment=ft.MainAxisAlignment.END,
      shape=ft.RoundedRectangleBorder(radius=3),
    )
    page.overlay.append(dlg)
    dlg.open = True
    page.update()

  async def handle_save_skill(skill_dict: dict):
    """Install/validate a skill and refresh the skill list from the DB."""
    await engine.save_skill_config(skill_dict)
    loaded = await engine.load_skill_configs()
    set_skill_configs(loaded)

  def handle_delete_skill(skill_id: str, on_confirmed=None):
    """Show a confirmation dialog then delete the skill and its installed files."""
    def close_dlg(e):
      dlg.open = False
      page.update()

    async def do_delete(e):
      await engine.delete_skill_config(skill_id)
      loaded = await engine.load_skill_configs()
      set_skill_configs(loaded)
      if on_confirmed:
        on_confirmed()
      close_dlg(e)

    dlg = ft.AlertDialog(
      modal=True,
      title=ft.Text("Remove Skill"),
      content=ft.Text("Are you sure you want to remove this skill and delete its installed files?"),
      actions=[
        ft.TextButton(
          "Remove", on_click=do_delete,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3))
        ),
        ft.TextButton(
          "Cancel", on_click=close_dlg,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3))
        ),
      ],
      actions_alignment=ft.MainAxisAlignment.END,
      shape=ft.RoundedRectangleBorder(radius=3),
    )
    page.overlay.append(dlg)
    dlg.open = True
    page.update()

  async def handle_save_tool(tool_dict: dict):
    """Persist a tool config and refresh the tool list from the DB."""
    await engine.save_tool_config(tool_dict)
    loaded = await engine.load_tool_configs()
    set_tool_configs(loaded)

  def handle_delete_tool(tool_id: str, on_confirmed=None):
    """Show a confirmation dialog then delete the tool config."""
    def close_dlg(e):
      dlg.open = False
      page.update()

    async def do_delete(e):
      await engine.delete_tool_config(tool_id)
      loaded = await engine.load_tool_configs()
      set_tool_configs(loaded)
      if on_confirmed:
        on_confirmed()
      close_dlg(e)

    dlg = ft.AlertDialog(
      modal=True,
      title=ft.Text("Remove Tool"),
      content=ft.Text("Are you sure you want to remove this tool configuration?"),
      actions=[
        ft.TextButton(
          "Remove", on_click=do_delete,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3))
        ),
        ft.TextButton(
          "Cancel", on_click=close_dlg,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3))
        ),
      ],
      actions_alignment=ft.MainAxisAlignment.END,
      shape=ft.RoundedRectangleBorder(radius=3),
    )
    page.overlay.append(dlg)
    dlg.open = True
    page.update()

  async def load_workspaces():
    async with engine.db.get_session() as session:
      result = await session.scalars(select(Workspace))
      set_workspaces(result.all())

  async def load_threads(workspace_id=None):
    async with engine.db.get_session() as session:
      # Sort by updated_at when available, fall back to created_at for older rows
      recency = func.coalesce(Thread.updated_at, Thread.created_at).desc()
      if workspace_id:
        stmt = select(Thread).where(Thread.workspace_id == workspace_id).order_by(recency)
      else:
        stmt = select(Thread).order_by(recency)
      
      result = await session.scalars(stmt)
      set_threads(result.all())

  def on_workspace_change():
    # Restore the previously selected thread for this workspace (if any)
    ws_key = active_chat_workspace.id if active_chat_workspace else None
    restored = thread_by_workspace.get(ws_key)
    if restored:
      set_selected_thread(restored)

      async def _restore_thread(tid):
        await load_messages(tid)
        # Restore the thread's persisted model on workspace switch
        set_selected_model_config(await resolve_thread_model(tid))

      asyncio.create_task(_restore_thread(restored.id))
    else:
      set_selected_thread(None)
      set_messages([])
    if show_all_threads:
      asyncio.create_task(load_threads())
    elif active_chat_workspace:
      asyncio.create_task(load_threads(active_chat_workspace.id))
    else:
      asyncio.create_task(load_threads())
  
  ft.use_effect(on_workspace_change, [active_chat_workspace])

  def on_show_all_threads_change():
    """Reload thread list when the all-threads toggle changes and persist the choice."""
    asyncio.create_task(engine.save_ui_state("ui_show_all_threads", "true" if show_all_threads else "false"))
    if show_all_threads:
      asyncio.create_task(load_threads())
    elif active_chat_workspace:
      asyncio.create_task(load_threads(active_chat_workspace.id))
    else:
      asyncio.create_task(load_threads())

  ft.use_effect(on_show_all_threads_change, [show_all_threads])

  async def load_messages(thread_id):
    db_msgs = await engine.load_thread_messages(thread_id)
    ui_msgs = []
    for m in db_msgs:
      ts = m.created_at.replace(tzinfo=timezone.utc) if m.created_at else datetime.now(timezone.utc)
      ui_msgs.append(_db_message_to_ui(m.role, m.content, ts))
    set_messages(ui_msgs)

  def on_mount():
    asyncio.create_task(load_threads())
    asyncio.create_task(load_settings())
    asyncio.create_task(load_workspaces())
    asyncio.create_task(restore_ui_state())
  
  ft.use_effect(on_mount, [])

  def subscribe_jobs():
    """Subscribe to the engine EventBus and mirror background job state into the
    UI so the notifications popup updates live as jobs progress."""
    queue = engine.events.subscribe()
    set_jobs(engine.jobs.list())

    async def _consume():
      try:
        while True:
          event = await queue.get()
          if str(event.get("type", "")).startswith("job."):
            set_jobs(engine.jobs.list())
      except asyncio.CancelledError:
        pass

    task = asyncio.create_task(_consume())

    def cleanup():
      engine.events.unsubscribe(queue)
      task.cancel()

    return cleanup

  ft.use_effect(subscribe_jobs, [])

  def open_notifications(e=None):
    set_jobs(engine.jobs.list())
    set_notifications_open(True)

  def close_notifications(e=None):
    set_notifications_open(False)

  def clear_finished_jobs(e=None):
    engine.jobs.clear_finished()
    set_jobs(engine.jobs.list())

  async def handle_new_workspace(e):
    set_editing_workspace(None)
    set_workspace_mode("create")
    set_current_view("workspaces")
    set_current_context("workspaces")
    set_ws_tools_config({})
    set_ws_skills_config({})
    set_ws_approval_config({})
    set_ws_directories([])

    # Save state
    asyncio.create_task(engine.save_ui_state("ui_selected_workspace_id", ""))
    asyncio.create_task(engine.save_ui_state("ui_current_view", "workspaces"))
    asyncio.create_task(engine.save_ui_state("ui_current_context", "workspaces"))

  async def handle_workspace_click(workspace):
    set_editing_workspace(workspace)
    set_workspace_mode("edit")
    set_current_view("workspaces")
    set_current_context("workspaces")
    set_ws_tools_config(Engine._parse_json_config(getattr(workspace, "tools_config", None)))
    set_ws_skills_config(Engine._parse_json_config(getattr(workspace, "skills_config", None)))
    set_ws_approval_config(Engine._parse_json_config(getattr(workspace, "approval_config", None)))
    set_ws_directories(Engine._parse_json_list(getattr(workspace, "directories", None)))

    # Save state
    asyncio.create_task(engine.save_ui_state("ui_current_view", "workspaces"))
    asyncio.create_task(engine.save_ui_state("ui_current_context", "workspaces"))
    asyncio.create_task(engine.save_ui_state("ui_selected_workspace_id", str(workspace.id) or ""))
  
  async def handle_settings_click(setting):
    if setting == "about":
      set_about_badge_dismissed(True)
    set_selected_setting(setting)
    asyncio.create_task(engine.save_ui_state("ui_selected_setting", setting or ""))

  async def handle_new_thread(e=None):
    set_selected_thread(None)
    set_messages([])
    set_current_view("threads")
    set_current_context("threads")
    set_chatbox_restore_token(chatbox_restore_token + 1)

    # Save state
    asyncio.create_task(engine.save_ui_state("ui_selected_thread_id", ""))
    asyncio.create_task(engine.save_ui_state("ui_current_view", "threads"))
    asyncio.create_task(engine.save_ui_state("ui_current_context", "threads"))
  
  async def handle_thread_click(thread):
    set_selected_thread(thread)
    set_current_view("threads")
    set_chatbox_restore_token(chatbox_restore_token + 1)

    # Save state
    asyncio.create_task(engine.save_ui_state("ui_current_view", "threads"))
    asyncio.create_task(engine.save_ui_state("ui_current_context", "threads"))
    asyncio.create_task(engine.save_ui_state("ui_selected_thread_id", str(thread.id)))

    # Remember which thread was selected for this workspace so we can restore it later
    ws_key = active_chat_workspace.id if active_chat_workspace else None
    set_thread_by_workspace({**thread_by_workspace, ws_key: thread})

    # Restore the persisted model config for this thread. 'default'/NULL and
    # ids pointing at a deleted model both fall back to the first config.
    set_selected_model_config(await resolve_thread_model(thread.id, model_configs))

    # Load messages from DB and convert to UI message objects
    db_msgs = await engine.load_thread_messages(thread.id)
    ui_msgs = []
    for m in db_msgs:
      ts = m.created_at.replace(tzinfo=timezone.utc) if m.created_at else datetime.now(timezone.utc)
      ui_msgs.append(_db_message_to_ui(m.role, m.content, ts))
    set_messages(ui_msgs)

  def handle_model_select(model_cfg: dict):
    """Persist the selected model config for the current thread and update state."""
    set_selected_model_config(model_cfg)
    if selected_thread:
      # Store 'default' when the first config is chosen so the thread isn't
      # locked to a specific UUID if the model list changes later.
      is_default = model_configs and model_cfg.get("id") == model_configs[0].get("id")
      model_id_to_store = "default" if is_default else model_cfg.get("id", "default")
      asyncio.create_task(engine.set_thread_model_id(selected_thread.id, model_id_to_store))

  async def handle_send_message(content, attachments=None):
    """
    Full message lifecycle:
    1. Resolve / create thread and workspace.
    2. Persist the user message to the DB.
    3. Add the user bubble immediately to the UI.
    4. Create an empty AI bubble and stream tokens into it live.
    5. Persist the completed AI message to the DB.
    6. Refresh the threads list (title may have been updated).
    """
    if not content.strip():
      return

    set_is_streaming(True)

    # --- 1. Resolve workspace ---
    workspace_id: int | None = active_chat_workspace.id if active_chat_workspace else None
    if workspace_id is None:
      async with engine.db.get_session() as session:
        first_ws = await session.scalar(select(Workspace))
        if first_ws:
          workspace_id = first_ws.id
        else:
          logger.error("No workspace available to attach message to.")
          set_is_streaming(False)
          return

    # --- 2. Get or create thread ---
    is_new_thread = (selected_thread is None)
    thread = await engine.get_or_create_thread(
      content=content,
      workspace_id=workspace_id,
      thread_id=selected_thread.id if selected_thread else None,
    )

    # --- 3. Persist user message (store original text, not the expanded prompt) ---
    user_db_msg = await engine.save_message(thread.id, "user", content)

    # --- 4. Update UI: show user bubble immediately ---
    user_ui_msg = HumanMessage(
      content=content,
      timestamp=user_db_msg.created_at.replace(tzinfo=timezone.utc)
        if user_db_msg.created_at else datetime.now(timezone.utc),
    )
    # If we just created a new thread, set it as selected so the UI shows the header
    if is_new_thread:
      set_selected_thread(thread)
      set_current_view("threads")
      # Seed the model for the new thread: always 'default' so it tracks the
      # first model config rather than being pinned to a specific UUID.
      asyncio.create_task(engine.set_thread_model_id(thread.id, "default"))

    new_messages = list(messages) + [user_ui_msg]
    set_messages(new_messages)

    # --- 5. Create streaming AI bubble ---
    # Use the same timestamp convention as human messages and DB-loaded messages
    # (naive local time labelled UTC) so the displayed time matches. Using
    # datetime.now(timezone.utc) here produced a real-UTC time that rendered
    # offset from local in the bubble.
    ai_ui_msg = AIMessage(content="", timestamp=datetime.now().replace(tzinfo=timezone.utc))
    stream_msgs = new_messages + [ai_ui_msg]
    set_messages(list(stream_msgs))

    # --- 6. Stream structured events, rendering a bubble per block ---
    # A single turn interleaves narration text, tool calls, and (when a tool is
    # gated) approval prompts. Each becomes its own bubble. `current_text`
    # buffers the active text block (shown live via streaming_text); tool
    # results and approval prompts flush it and append their own bubble.
    current_text = ""
    pending_args: dict = {}
    approval_msgs: dict = {}
    set_streaming_text("")  # Reset before starting

    def _now():
      return datetime.now().replace(tzinfo=timezone.utc)

    def _ensure_text_placeholder():
      # Guarantee a trailing empty AI bubble so streaming_text has a target.
      if not (stream_msgs and stream_msgs[-1].type == "ai"):
        stream_msgs.append(AIMessage(content="", timestamp=_now()))

    async def _flush_text():
      # Commit buffered narration into the trailing AI bubble (persisting it),
      # or drop that bubble when the block produced no text.
      nonlocal current_text
      if stream_msgs and stream_msgs[-1].type == "ai":
        if current_text.strip():
          stream_msgs[-1].content = current_text
          await engine.save_message(thread.id, "assistant", current_text)
        else:
          stream_msgs.pop()
      current_text = ""

    try:
      async for event in engine.stream_chat_events(
        content=content,
        thread_id=thread.id,
        workspace_id=workspace_id,
        attachments=attachments or [],
        model_cfg=selected_model_config or (model_configs[0] if model_configs else None),
      ):
        if isinstance(event, TextDelta):
          _ensure_text_placeholder()
          current_text += event.content
          # A dedicated scalar guarantees Flet re-renders ChatWindow, which
          # overlays streaming_text onto the trailing (empty) AI bubble.
          set_streaming_text(current_text)

        elif isinstance(event, ToolCallStarted):
          # Capture args now; the matching result arrives as a later event.
          pending_args[event.tool_call_id] = event.args

        elif isinstance(event, ToolCallResult):
          await _flush_text()
          tool_json = tool_block_to_json(
            tool_name=event.tool_name,
            args=pending_args.pop(event.tool_call_id, None),
            output=event.content,
            tool_call_id=event.tool_call_id,
            outcome=event.outcome,
          )
          await engine.save_message(thread.id, "tool", tool_json)
          stream_msgs.append(ToolMessage(content=tool_json, timestamp=_now()))
          set_streaming_text("")
          set_messages(list(stream_msgs))

        elif isinstance(event, ApprovalRequest):
          # A gated tool is waiting: flush narration, then show an approval
          # prompt whose buttons resolve the pending decision on the engine.
          await _flush_text()
          appr = ApprovalMessage(
            tool_name=event.tool_name,
            args=event.args,
            tool_call_id=event.tool_call_id,
            operation=event.operation,
            engine=engine,
            timestamp=_now(),
          )
          approval_msgs[event.tool_call_id] = appr
          stream_msgs.append(appr)
          set_streaming_text("")
          set_messages(list(stream_msgs))

        elif isinstance(event, ApprovalResolved):
          appr = approval_msgs.get(event.tool_call_id)
          if appr is not None:
            appr.resolved = event.approved
          set_messages(list(stream_msgs))

    except Exception as exc:
      logger.error(f"LLM stream error: {exc}")
      _ensure_text_placeholder()
      current_text = (current_text + f"\n\n⚠ Error reaching the model: {exc}").strip()
      set_streaming_text(current_text)

    # --- 7. Commit the final text block and persist it ---
    await _flush_text()
    set_messages(list(stream_msgs))
    set_streaming_text("")

    # --- 8. Refresh thread list so new/renamed threads appear ---
    await load_threads(workspace_id)
    # Re-select the thread so the context list highlights it correctly
    set_selected_thread(thread)
    # Keep workspace→thread map up-to-date
    ws_key = active_chat_workspace.id if active_chat_workspace else None
    set_thread_by_workspace({**thread_by_workspace, ws_key: thread})
    set_is_streaming(False)

    # Scroll the chat list to the bottom now that the full response is visible.
    # asyncio.create_task(scroll_to_end(chat_scroll_ref[0]))
  
  async def scroll_to_end(msgs):
    """ Scrolls to bottom of chat after new message """
    while not msgs.did_mount():
      await asyncio.sleep(1)

    if msgs is not None:
      await msgs.scroll_to(offset=-1, duration=300)


  def handle_workspace_tools_change(config):
    """Persist the editing workspace's tool toggle config (defaults for its threads)."""
    if not editing_workspace:
      return
    set_ws_tools_config(dict(config))
    asyncio.create_task(engine.set_workspace_tools_config(editing_workspace.id, config))

  def handle_workspace_skills_change(config):
    """Persist the editing workspace's skill toggle config."""
    if not editing_workspace:
      return
    set_ws_skills_config(dict(config))
    asyncio.create_task(engine.set_workspace_skills_config(editing_workspace.id, config))

  def handle_workspace_approval_change(config):
    """Persist the editing workspace's HITL approval policy."""
    if not editing_workspace:
      return
    set_ws_approval_config(dict(config))
    asyncio.create_task(engine.set_workspace_approval_config(editing_workspace.id, config))

  def handle_workspace_directories_change(directories):
    """Persist the editing workspace's attached directory list and (re)index."""
    if not editing_workspace:
      return
    set_ws_directories(list(directories))
    asyncio.create_task(engine.set_workspace_directories(editing_workspace.id, directories))
    # Kick off a background re-index so new directory contents become searchable
    # (and removed directories get pruned). Progress shows in the notifications popup.
    engine.reindex_workspace(editing_workspace.id, editing_workspace.name)

  async def handle_open_thread_tools(e=None):
    """Resolve the active thread's tool config and open the tools dialog."""
    if not selected_thread:
      return
    ws_id = active_chat_workspace.id if active_chat_workspace else selected_thread.workspace_id
    cfg = await engine.resolve_tools_config(ws_id, selected_thread.id)
    acfg = await engine.resolve_approval_config(ws_id, selected_thread.id)
    set_thread_dialog_cfg(cfg)
    set_thread_dialog_approval_cfg(acfg)
    set_thread_dialog_mode("tools")

  async def handle_open_thread_skills(e=None):
    """Resolve the active thread's skill config and open the skills dialog."""
    if not selected_thread:
      return
    ws_id = active_chat_workspace.id if active_chat_workspace else selected_thread.workspace_id
    cfg = await engine.resolve_skills_config(ws_id, selected_thread.id)
    set_thread_dialog_cfg(cfg)
    set_thread_dialog_mode("skills")

  def close_thread_dialog(e=None):
    set_thread_dialog_mode(None)

  def handle_thread_tools_change(config):
    """Persist a thread-level tools override."""
    if selected_thread:
      asyncio.create_task(engine.set_thread_tools_config(selected_thread.id, config))

  def handle_thread_approval_change(config):
    """Persist a thread-level HITL approval override."""
    if selected_thread:
      set_thread_dialog_approval_cfg(dict(config))
      asyncio.create_task(engine.set_thread_approval_config(selected_thread.id, config))

  def handle_thread_skills_change(config):
    """Persist a thread-level skills override."""
    if selected_thread:
      asyncio.create_task(engine.set_thread_skills_config(selected_thread.id, config))

  async def handle_save_workspace(name, description, ws_id=None):
    async with engine.db.get_session() as session:
      if ws_id:
        ws = await session.get(Workspace, ws_id)
        if ws:
          ws.name = name
          ws.description = description
      else:
        ws = Workspace(name=name, description=description, network_id=engine.current_network.value, uuid=str(uuid.uuid4()))
        session.add(ws)
      await session.commit()
      await session.refresh(ws)
    await load_workspaces()
    set_editing_workspace(ws)
    set_workspace_mode("edit")
    set_current_view("workspaces")

  async def handle_delete_workspace(ws_id):
    def close_dlg(e):
      dlg.open = False
      page.update()

    async def do_delete(e):
      async with engine.db.get_session() as session:
        ws = await session.get(Workspace, ws_id)
        if ws:
          await session.delete(ws)
          await session.commit()
      close_dlg(e)
      await load_workspaces()
      set_editing_workspace(None)
      set_workspace_mode("view")
      set_current_view("workspaces")

    dlg = ft.AlertDialog(
      modal=True,
      title=ft.Text("Confirm Deletion"),
      content=ft.Text("Are you sure you want to delete this workspace?"),
      actions=[
        ft.TextButton(
          "Yes", on_click=do_delete,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3))
        ),
        ft.TextButton(
          "No", on_click=close_dlg,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3))
        ),
      ],
      actions_alignment=ft.MainAxisAlignment.END,
      shape=ft.RoundedRectangleBorder(radius=3),
    )
    page.overlay.append(dlg)
    dlg.open = True
    page.update()

  def toggle_context(e=None):
    set_context_visible(not context_visible)
    asyncio.create_task(engine.save_ui_state("ui_context_visible", "true" if not context_visible else "false"))
    
  def handle_context_width_change(delta_x):
    new_width = context_width + delta_x
    if 200 <= new_width <= 700:
      set_context_width(new_width)

  async def switch_to_workspace(e=None):
    set_context_visible(True)
    set_current_view("workspaces")
    set_current_context("workspaces")

    # Save state
    asyncio.create_task(engine.save_ui_state("ui_context_visible", "true"))
    asyncio.create_task(engine.save_ui_state("ui_current_view", "workspaces"))
    asyncio.create_task(engine.save_ui_state("ui_current_context", "workspaces"))

  async def switch_to_threads(e=None):
    set_context_visible(True)
    set_current_view("threads")
    set_current_context("threads")
    set_chatbox_restore_token(chatbox_restore_token + 1)

    # Save state
    asyncio.create_task(engine.save_ui_state("ui_current_view", "threads"))
    asyncio.create_task(engine.save_ui_state("ui_context_visible", "true"))
    asyncio.create_task(engine.save_ui_state("ui_current_context", "threads"))

  def handle_chat_workspace_change(workspace):
    """Switch the active chat workspace and reset the all-threads view."""
    set_show_all_threads(False)
    set_active_chat_workspace(workspace)
    asyncio.create_task(engine.save_ui_state("ui_active_workspace_id", str(workspace.id) if workspace else ""))

  async def switch_to_settings(e=None):
    set_settings_badge_dismissed(True)
    set_current_view("settings")
    set_current_context("settings")
    set_context_visible(True)

    # Save state
    asyncio.create_task(engine.save_ui_state("ui_context_visible", "true"))
    asyncio.create_task(engine.save_ui_state("ui_current_view", "settings"))
    asyncio.create_task(engine.save_ui_state("ui_current_context", "settings"))

  async def switch_to_account(e=None):
    set_current_view("account")
    set_current_context("account")
    set_context_visible(False)
    
    # Save state
    asyncio.create_task(engine.save_ui_state("ui_current_view", "account"))
    asyncio.create_task(engine.save_ui_state("ui_context_visible", "false"))
    asyncio.create_task(engine.save_ui_state("ui_current_context", "account"))
  
  # Register window event callback
  page.window.on_event = handle_window_event

  # Determine which workspace to surface in the chat header. When "All Workspaces"
  # is active, reflect the workspace the selected thread actually belongs to
  # instead of the (now ambiguous) active_chat_workspace.
  if show_all_threads:
    header_workspace = next(
      (w for w in workspaces if selected_thread and w.id == selected_thread.workspace_id),
      None,
    )
  else:
    header_workspace = active_chat_workspace

  # Thread-level Tools/Skills dialog. Kept mounted with a stable key and toggled
  # via `open` rather than being added/removed from the tree — removing an open
  # AlertDialog leaves it stuck on screen (the reported "Done does nothing" bug),
  # whereas flipping `open` triggers a proper dismiss animation.
  thread_dialog = None
  if selected_thread is not None:
    is_skills = thread_dialog_mode == "skills"
    if is_skills:
      dialog_title = "Thread Skills"
      dialog_body: ft.Control = SkillToggleList(
        skills=skill_configs,
        config=thread_dialog_cfg,
        on_change=handle_thread_skills_change,
        sync_key=selected_thread.id,
      )
      dialog_height = 420
    else:
      dialog_title = "Thread Tools"
      dialog_body = ToolToggleTree(
        catalog=tool_catalog,
        configured_tools=tool_configs,
        config=thread_dialog_cfg,
        on_change=handle_thread_tools_change,
        approval_config=thread_dialog_approval_cfg,
        on_approval_change=handle_thread_approval_change,
        sync_key=selected_thread.id,
      )
      dialog_height = 520
    thread_dialog = ft.AlertDialog(
      key="thread-dialog",
      open=thread_dialog_mode in ("tools", "skills"),
      modal=False,
      title=ft.Text(dialog_title),
      content=ft.Container(
        content=ft.Column([dialog_body], scroll=ft.ScrollMode.ADAPTIVE, tight=True),
        width=420,
        height=dialog_height,
      ),
      actions=[
        ft.TextButton(
          "Done",
          on_click=close_thread_dialog,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
        ),
      ],
      actions_alignment=ft.MainAxisAlignment.END,
      shape=ft.RoundedRectangleBorder(radius=3),
      on_dismiss=close_thread_dialog,
    )

  # Background-jobs / notifications popup — shows ongoing work (e.g. indexing).
  def _job_row(j: dict) -> ft.Control:
    status = j.get("status", "running")
    running = status == "running"
    status_colours = {
      "running":   ft.Colors.PRIMARY,
      "completed": ft.Colors.GREEN,
      "failed":    ft.Colors.ERROR,
      "cancelled": ft.Colors.GREY,
    }
    indeterminate = running and not j.get("total")
    body: list = [
      ft.Row(
        [
          ft.Text(j.get("title", "Job"), weight=ft.FontWeight.W_500, expand=True, color=ft.Colors.PRIMARY),
          ft.Text(status.capitalize(), size=12, color=status_colours.get(status, ft.Colors.GREY)),
        ],
        spacing=8,
      ),
    ]
    if running:
      body.append(ft.ProgressBar(value=None if indeterminate else j.get("progress", 0.0)))
    if j.get("message"):
      body.append(
        ft.Text(j["message"], size=12, color=ft.Colors.GREY, max_lines=1, overflow=ft.TextOverflow.ELLIPSIS)
      )
    return ft.Container(
      content=ft.Column(body, spacing=6),
      padding=ft.padding.all(10),
      bgcolor=ft.Colors.SURFACE_CONTAINER_HIGHEST,
      border_radius=ft.BorderRadius(3, 3, 3, 3),
    )

  job_controls = [_job_row(j) for j in jobs] if jobs else [
    ft.Container(
      content=ft.Text("No background jobs.", size=14, color=ft.Colors.GREY_600),
      padding=ft.padding.all(10),
    )
  ]
  active_jobs = sum(1 for j in jobs if j.get("status") == "running")

  notifications_dialog = ft.AlertDialog(
    key="notifications-dialog",
    open=notifications_open,
    modal=False,
    title=ft.Row(
      [
        ft.Text("Background Jobs", expand=True),
        ft.TextButton(
          "Clear finished",
          on_click=clear_finished_jobs,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
        ),
      ],
      spacing=8,
    ),
    content=ft.Container(
      content=ft.Column(job_controls, scroll=ft.ScrollMode.ADAPTIVE, spacing=10, tight=True),
      width=440,
      height=420,
    ),
    actions=[
      ft.TextButton(
        "Close",
        on_click=close_notifications,
        style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
      ),
    ],
    actions_alignment=ft.MainAxisAlignment.END,
    shape=ft.RoundedRectangleBorder(radius=3),
    on_dismiss=close_notifications,
  )

  view = [
    TitleBar(dev=engine.config.dev),
    Frame(
      sidebar=Sidebar(
        on_workspace_click=switch_to_workspace,
        on_threads_click=switch_to_threads,
        on_settings_click=switch_to_settings,
        on_account_click=switch_to_account,
        on_context_toggle=toggle_context,
        selected_view=current_context, # Use context to light up the sidebar icon correctly
        config=engine.config,
        show_settings_badge=bool(engine.update_available) and not settings_badge_dismissed,
        on_notifications_click=open_notifications,
        active_jobs=active_jobs,
      ),
      contextlist=ContextList(
        visible=context_visible,
        width=context_width,
        current_view=current_view,
        current_context=current_context,
        on_workspace_select=switch_to_threads,
        workspaces_list=workspaces,
        on_new_workspace=handle_new_workspace,
        on_workspace_selected_for_edit=handle_workspace_click,
        editing_workspace=editing_workspace,
        threads_list=threads,
        on_new_thread=handle_new_thread,
        on_thread_select=handle_thread_click,
        selected_thread=selected_thread,
        active_chat_workspace=active_chat_workspace,
        on_chat_workspace_change=handle_chat_workspace_change,
        selected_setting=selected_setting,
        set_selected_setting=handle_settings_click,
        show_about_badge=bool(engine.update_available) and not about_badge_dismissed,
        show_all_threads=show_all_threads,
        on_toggle_all_threads=set_show_all_threads
      ),
      mainwindow=MainWindow(
        current_view=current_view,
        workspace=editing_workspace,
        workspace_mode=workspace_mode,
        settings_mode=selected_setting,
        on_save_workspace=handle_save_workspace,
        on_delete_workspace=handle_delete_workspace,
        thread=selected_thread,
        messages=messages,
        streaming_text=streaming_text,
        on_list_mounted=on_list_mounted,
        on_send_message=handle_send_message,
        is_streaming=is_streaming,
        settings=settings,
        on_setting_change=handle_setting_change,
        model_configs=model_configs,
        on_save_model=handle_save_model,
        on_delete_model=handle_delete_model,
        model_expanded_indices=model_expanded_indices,
        set_model_expanded_indices=set_model_expanded_indices,
        skill_configs=skill_configs,
        on_save_skill=handle_save_skill,
        on_delete_skill=handle_delete_skill,
        skill_expanded_indices=skill_expanded_indices,
        set_skill_expanded_indices=set_skill_expanded_indices,
        tool_configs=tool_configs,
        on_save_tool=handle_save_tool,
        on_delete_tool=handle_delete_tool,
        tool_expanded_indices=tool_expanded_indices,
        set_tool_expanded_indices=set_tool_expanded_indices,
        update_available=bool(engine.update_available),
        on_update=engine.run_update,
        selected_model_config=selected_model_config,
        on_model_select=handle_model_select,
        initial_chatbox_text=initial_chatbox_text,
        initial_chatbox_attachments=initial_chatbox_attachments,
        on_chatbox_change=handle_chatbox_change,
        chatbox_restore_token=chatbox_restore_token,
        active_workspace=header_workspace,
        tool_catalog=tool_catalog,
        workspace_tools_config=ws_tools_config,
        workspace_skills_config=ws_skills_config,
        workspace_directories=ws_directories,
        on_workspace_tools_change=handle_workspace_tools_change,
        on_workspace_skills_change=handle_workspace_skills_change,
        workspace_approval_config=ws_approval_config,
        on_workspace_approval_change=handle_workspace_approval_change,
        on_workspace_directories_change=handle_workspace_directories_change,
        on_open_thread_tools=handle_open_thread_tools,
        on_open_thread_skills=handle_open_thread_skills,
        data_dir=str(engine.config.data_dir),
      ),
      context_visible=context_visible,
      on_context_width_change=handle_context_width_change,
      workspace_name=active_chat_workspace.name if active_chat_workspace else "All Workspaces"
    )
  ]

  if thread_dialog is not None:
    view.append(thread_dialog)

  view.append(notifications_dialog)

  return view

async def main(page: ft.Page, engine):
  """ Application window config """
  page.padding = 0
  page.spacing = 0
  page.title = "Subconscious"
  page.window.min_width = 506
  page.window.min_height = 300
  page.window.frameless = False
  page.window.icon = "favicon.ico" # Windows only
  page.bgcolor = ft.Colors.SURFACE
  page.window.title_bar_hidden = True
  page.theme_mode = ft.ThemeMode.LIGHT

  # Could put load settings here

  # Start rendering Subconscious
  return page.render(lambda: AppView(page, engine))

async def start_gui(config):
  """ Starts the GUI, engine & tray """
  assets_path = str(pathlib.Path(__file__).parent.parent / "assets")
  logger.debug(f"assets_path resolved to: {assets_path}")
  
  logger.info("Starting engine...")
  engine = Engine()
  await engine.start_engine(config)

  # Create tray and close event to stop the engine
  logger.info("Creating background service...")
  close = asyncio.Event()
  try:
    tray = Tray(engine, close)
  except Exception:
    logger.error("Failed to create background service:\n" + traceback.format_exc())
    raise

  async def handle_close():
    await close.wait()
    await engine.stop_engine()

  asyncio.create_task(handle_close())
  
  async def main_wrapper(page: ft.Page):
    tray.set_gui(page)
    await main(page, engine)
  
  logger.info("Starting GUI...")
  try:
    await tray.start_gui(main_wrapper, assets_path)
  except Exception:
    logger.error("Exception in tray.start_gui:\n" + traceback.format_exc())
    raise
  logger.info("Shutting down...")
