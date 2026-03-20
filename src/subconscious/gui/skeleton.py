import uuid
import asyncio
import pathlib
import logging
import flet as ft
from sqlalchemy import select
from datetime import datetime, timezone
from dataclasses import dataclass, field

from ..engine import Engine
from ..gui.frame import Frame
from ..gui.sidebar import Sidebar
from ..gui.titlebar import TitleBar
from ..gui.components.tray import *
from ..gui.mainwindow import MainWindow
from ..gui.contextlist import ContextList
from ..db.models import Workspace, Thread, AppState
from ..gui.components.messages import HumanMessage, AIMessage


logger = logging.getLogger("subconscious")


@ft.observable
@dataclass
class User:
  first_name: str
  last_name: str

  def update(self, first_name: str, last_name: str):
    self.first_name = first_name
    self.last_name = last_name


@ft.observable
@dataclass
class App:
  users: list[User] = field(default_factory=list)

  def add_user(self, first_name: str, last_name: str):
    if first_name.strip() or last_name.strip():
      self.users.append(User(first_name, last_name))

  def delete_user(self, user: User):
    self.users.remove(user)
  

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
  # Should package the app and then decide how to do-it, not certain how the splash screen works at present
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
  # Persists the last-selected thread per workspace so it's restored on switch-back
  thread_by_workspace, set_thread_by_workspace = ft.use_state(dict())
  # When True the threads list shows threads across all workspaces
  show_all_threads, set_show_all_threads = ft.use_state(False)

  # Settings Management State
  selected_setting, set_selected_setting = ft.use_state(None)
  settings, set_settings = ft.use_state({})
  # Model configs loaded from encrypted storage: list of dicts
  model_configs, set_model_configs = ft.use_state([])
  # Expanded panel indices for the model settings list - persisted across navigation
  model_expanded_indices, set_model_expanded_indices = ft.use_state(set())

  async def load_settings():
    async with engine.db.get_session() as session:
      stmt = select(AppState).where(AppState.tag.in_(["system", "general"]))
      result = await session.scalars(stmt)
      db_settings = {s.key: s.value for s in result.all()}
      set_settings(db_settings)
      
      # Apply some settings immediately if needed
      if "mode" in db_settings:
        page.theme_mode = ft.ThemeMode.DARK if db_settings["mode"] == "dark" else ft.ThemeMode.LIGHT
      page.update()

    # Load model configs from encrypted storage
    engine.config.read_keyring()
    raw_models = engine.config.secrets.get("models", {})
    # secrets["models"] is stored as {uuid: {...fields}} – convert to list
    loaded = [{"id": k, **v} for k, v in raw_models.items()]
    set_model_configs(loaded)

  async def handle_setting_change(key, value, tag):
    print("Settings Changed")

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

  async def load_workspaces():
    async with engine.db.get_session() as session:
      result = await session.scalars(select(Workspace))
      set_workspaces(result.all())

  async def load_threads(workspace_id=None):
    from sqlalchemy import func, case
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
      asyncio.create_task(load_messages(restored.id))
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
    """Reload thread list when the all-threads toggle changes."""
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
      if m.role == "user":
        ui_msgs.append(HumanMessage(content=m.content, timestamp=ts))
      else:
        ui_msgs.append(AIMessage(content=m.content, timestamp=ts))
    set_messages(ui_msgs)

  def on_mount():
    asyncio.create_task(load_workspaces())
    asyncio.create_task(load_threads())
    asyncio.create_task(load_settings())
  
  ft.use_effect(on_mount, [])

  async def handle_new_workspace(e):
    set_editing_workspace(None)
    set_workspace_mode("create")
    set_current_view("workspaces")
    set_current_context("workspaces")

  async def handle_workspace_click(workspace):
    set_editing_workspace(workspace)
    set_workspace_mode("edit")
    set_current_view("workspaces")
    set_current_context("workspaces")
  
  async def handle_settings_click(setting):
    set_selected_setting(setting)

  async def handle_new_thread(e=None):
    set_selected_thread(None)
    set_messages([])
    set_current_view("threads")
    set_current_context("threads")
  
  async def handle_thread_click(thread):
    set_selected_thread(thread)
    set_current_view("threads")
    # Remember which thread was selected for this workspace so we can restore it later
    ws_key = active_chat_workspace.id if active_chat_workspace else None
    set_thread_by_workspace({**thread_by_workspace, ws_key: thread})

    # Load messages from DB and convert to UI message objects
    db_msgs = await engine.load_thread_messages(thread.id)
    ui_msgs = []
    for m in db_msgs:
      ts = m.created_at.replace(tzinfo=timezone.utc) if m.created_at else datetime.now(timezone.utc)
      if m.role == "user":
        ui_msgs.append(HumanMessage(content=m.content, timestamp=ts))
      else:
        ui_msgs.append(AIMessage(content=m.content, timestamp=ts))
    set_messages(ui_msgs)

  async def handle_send_message(content):
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

    # --- 3. Persist user message ---
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

    new_messages = list(messages) + [user_ui_msg]
    set_messages(new_messages)

    # --- 5. Create streaming AI bubble ---
    ai_ui_msg = AIMessage(content="", timestamp=datetime.now(timezone.utc))
    streaming_messages = new_messages + [ai_ui_msg]
    set_messages(streaming_messages)

    # --- 6. Stream from the LLM, accumulate, update bubble in-place ---
    full_response = ""
    try:
      async for chunk in engine.stream_chat(
        content=content,
        thread_id=thread.id,
        workspace_id=workspace_id,
      ):
        full_response += chunk
        ai_ui_msg.content = full_response
        # Reassign list so Flet detects state change and re-renders the bubble
        set_messages(list(streaming_messages))
    except Exception as exc:
      logger.error(f"LLM stream error: {exc}")
      ai_ui_msg.content = f"⚠ Error reaching the model: {exc}"
      set_messages(list(streaming_messages))

    # --- 7. Persist the final AI message ---
    if full_response:
      await engine.save_message(thread.id, "assistant", full_response)

    # --- 8. Refresh thread list so new/renamed threads appear ---
    await load_threads(workspace_id)
    # Re-select the thread so the context list highlights it correctly
    set_selected_thread(thread)
    # Keep workspace→thread map up-to-date
    ws_key = active_chat_workspace.id if active_chat_workspace else None
    set_thread_by_workspace({**thread_by_workspace, ws_key: thread})
    set_is_streaming(False)

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
    
  def handle_context_width_change(delta_x):
    new_width = context_width + delta_x
    if 200 <= new_width <= 700:
      set_context_width(new_width)

  async def toggle_theme(e=None):
    page.theme_mode = (
      ft.ThemeMode.DARK if page.theme_mode == ft.ThemeMode.LIGHT else ft.ThemeMode.LIGHT
    )

  async def switch_to_workspace(e=None):
    set_current_view("workspaces")
    set_current_context("workspaces")
    set_context_visible(True)

  async def switch_to_threads(e=None):
    set_current_view("threads")
    set_current_context("threads")
    set_context_visible(True)

  def handle_chat_workspace_change(workspace):
    """Switch the active chat workspace and reset the all-threads view."""
    set_show_all_threads(False)
    set_active_chat_workspace(workspace)

  async def switch_to_settings(e=None):
    set_current_view("settings")
    set_current_context("settings")
    set_context_visible(True)

  return [
    TitleBar(),
    Frame(
      sidebar=Sidebar(
        on_theme_toggle=toggle_theme,
        on_workspace_click=switch_to_workspace,
        on_threads_click=switch_to_threads,
        on_settings_click=switch_to_settings,
        on_context_toggle=toggle_context,
        selected_view=current_context # Use context to light up the sidebar icon correctly
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
        show_all_threads=show_all_threads,
        on_toggle_all_threads=lambda: set_show_all_threads(not show_all_threads)
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
        on_send_message=handle_send_message,
        is_streaming=is_streaming,
        settings=settings,
        on_setting_change=handle_setting_change,
        model_configs=model_configs,
        on_save_model=handle_save_model,
        on_delete_model=handle_delete_model,
        model_expanded_indices=model_expanded_indices,
        set_model_expanded_indices=set_model_expanded_indices
      ),
      context_visible=context_visible,
      on_context_width_change=handle_context_width_change,
      workspace_name=active_chat_workspace.name if active_chat_workspace else "General"
    )
  ]

async def main(page: ft.Page, engine):
  """ Application window config """
  page.padding = 0
  page.spacing = 0
  page.window.width = 800
  page.window.height = 800
  page.title = "Subconscious"
  page.window.min_width = 506
  page.window.min_height = 300
  page.window.frameless = False
  page.window.icon = "favicon.ico" # Windows only
  page.bgcolor = ft.Colors.SURFACE
  page.window.title_bar_hidden = True
  page.theme_mode = ft.ThemeMode.LIGHT
  page.theme = ft.Theme(color_scheme=ft.ColorScheme(primary=ft.Colors.BLACK, secondary=ft.Colors.GREY, surface=ft.Colors.WHITE, secondary_container=ft.Colors.GREY_300, primary_container=ft.Colors.GREY_300))
  page.dark_theme = ft.Theme(color_scheme=ft.ColorScheme(primary=ft.Colors.WHITE, secondary=ft.Colors.GREY, surface=ft.Colors.BLACK87, secondary_container=ft.Colors.GREY_800, primary_container=ft.Colors.GREY_800))

  # Start rendering Subconscious
  return page.render(lambda: AppView(page, engine))

async def start_gui(config):
  """ Starts the GUI, engine & tray """
  assets_path = str(pathlib.Path(__file__).parent.parent / "assets")
  engine = Engine()
  await engine.start_engine(config)

  # Create tray and close event to stop the engine
  close = asyncio.Event()
  tray = Tray(engine, close)

  async def handle_close():
    await close.wait()
    await engine.stop_engine()

  asyncio.create_task(handle_close())
  
  async def main_wrapper(page: ft.Page):
    tray.set_gui(page)
    await main(page, engine)
  
  await tray.start_gui(main_wrapper, assets_path)
