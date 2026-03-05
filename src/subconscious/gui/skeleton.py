import uuid
import asyncio
import pathlib
import flet as ft
from sqlalchemy import select
from dataclasses import dataclass, field

from ..engine import Engine
from ..gui.frame import Frame
from ..gui.sidebar import Sidebar
from ..gui.titlebar import TitleBar
from ..gui.mainwindow import MainWindow
from ..gui.contextlist import ContextList
from ..db.models import Workspace, Thread, Message


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
  selected_workspace, set_selected_workspace = ft.use_state(None)
  workspace_mode, set_workspace_mode = ft.use_state("view") # view, create, edit
  
  # Thread Management State
  threads, set_threads = ft.use_state(list())
  selected_thread, set_selected_thread = ft.use_state(None)
  messages, set_messages = ft.use_state(list())

  async def load_workspaces():
    async with engine.db.get_session() as session:
      result = await session.scalars(select(Workspace))
      set_workspaces(result.all())
      page.update()

  async def load_threads(workspace_id=None):
      async with engine.db.get_session() as session:
          if workspace_id:
              stmt = select(Thread).where(Thread.workspace_id == workspace_id).order_by(Thread.created_at.desc())
          else:
              # Depending on requirement, we might show all threads or no threads if no workspace selected
              # For now let's show all latest threads if no workspace selected (global view) or empty list
              stmt = select(Thread).order_by(Thread.created_at.desc())
          
          result = await session.scalars(stmt)
          set_threads(result.all())
          page.update()

  async def load_messages(thread_id):
      async with engine.db.get_session() as session:
          stmt = select(Message).where(Message.thread_id == thread_id).order_by(Message.created_at)
          result = await session.scalars(stmt)
          set_messages(result.all())
          page.update()

  def handle_new_workspace(e):
    # Deselect threads when creating a new workspace?
    # set_selected_thread(None)
    set_selected_workspace(None)
    set_workspace_mode("create")
    set_current_view("workspaces")
    set_current_context("workspaces")

  def handle_workspace_click(workspace):
    # set_selected_thread(None)
    set_selected_workspace(workspace)
    set_workspace_mode("edit")
    set_current_view("workspaces")
    set_current_context("workspaces")

  # Add logic to switch to threads for a workspace if we want that behavior later

  async def handle_thread_click(thread):
      set_selected_thread(thread)
      set_current_view("threads")
      await load_messages(thread.id)

  async def handle_save_workspace(name, description, ws_id=None):
    async with engine.db.get_session() as session:
      if ws_id:
        ws = await session.get(Workspace, ws_id)
        if ws:
          ws.name = name
      else:
        ws = Workspace(name=name, network_id=engine.current_network.value, uuid=str(uuid.uuid4()))
        session.add(ws)
      await session.commit()
    await load_workspaces()
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

  return [
    TitleBar(),
    Frame(
      sidebar=Sidebar(
        on_theme_toggle=toggle_theme,
        on_workspace_click=switch_to_workspace,
        on_threads_click=switch_to_threads,
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
        selected_workspace=selected_workspace,
        threads_list=threads,
        on_thread_select=handle_thread_click,
        selected_thread=selected_thread
      ),
      mainwindow=MainWindow(
        current_view=current_view,
        workspace=selected_workspace,
        workspace_mode=workspace_mode,
        on_save_workspace=handle_save_workspace,
        on_delete_workspace=handle_delete_workspace,
        messages=messages
      ),
      context_visible=context_visible,
      on_context_width_change=handle_context_width_change,
    )
  ]

async def main(page: ft.Page, config):
  """ Application window config """
  page.padding = 0
  page.spacing = 0
  page.window.width = 800
  page.window.height = 800
  page.title = "Subconscious"
  page.window.min_width = 506
  page.window.min_height = 506
  page.window.frameless = False
  page.bgcolor = ft.Colors.SURFACE
  page.window.title_bar_hidden = True
  page.theme_mode = ft.ThemeMode.LIGHT
  page.theme = ft.Theme(color_scheme=ft.ColorScheme(primary=ft.Colors.BLACK, secondary=ft.Colors.GREY, surface=ft.Colors.WHITE, secondary_container=ft.Colors.GREY_300, primary_container=ft.Colors.GREY_300))
  page.dark_theme = ft.Theme(color_scheme=ft.ColorScheme(primary=ft.Colors.WHITE, secondary=ft.Colors.GREY, surface=ft.Colors.BLACK87, secondary_container=ft.Colors.GREY_800, primary_container=ft.Colors.GREY_800))

  # Start the engine and gui
  engine = Engine()
  await engine.start_engine(config)
  return page.render(lambda: AppView(page, engine))

async def start_gui(config):
  """ Starts the GUI engine """
  assets_path = str(pathlib.Path(__file__).parent.parent / "assets")
  
  # create a wrapper so flet can call main(page)
  async def main_wrapper(page: ft.Page):
    await main(page, config)

  await ft.run_async(main_wrapper, assets_dir=assets_path)
