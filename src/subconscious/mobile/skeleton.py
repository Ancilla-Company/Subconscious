"""
Mobile version of Subconscious skeleton - optimized for mobile devices with flyout side panel.
"""
import asyncio
import pathlib
import logging
import time
import traceback
import flet as ft
# from sqlalchemy import select

from .drawer import Drawer
# from ..mobile_engine import MobileEngine
from ..shared.forms import *
from ..shared.layout import *
from ..shared.buttons import *
from ..shared.messages import *
# from ..config import Config, LOGO
# from .mainwindow import MainWindow
from ..mobile.chat import ChatWindow
# from ..db.models import Workspace, Thread, AppState


logger = logging.getLogger("subconscious")


# @ft.component
def MobileHeader(engine, current_view, set_current_view, on_menu_click) -> ft.Control:
  """Mobile header with menu icon and title"""
  return ft.Container(
    content=ft.Row([
      ft.IconButton(
        icon=ft.Icons.MENU,
        # on_click=on_menu_click,
        tooltip="Menu"
      ),
      ft.Text(
        "Subconscious",
        size=20,
        weight=ft.FontWeight.W_600,
        expand=True
      ),
      ft.IconButton(
        icon=ft.Icons.ADD,
        on_click=lambda e: None,  # Handle new thread
        tooltip="New Chat"
      )
    ], spacing=10, expand=True),
    padding=ft.padding.all(10),
    # bgcolor=ft.Colors.SURFACE_CONTAINER_HIGHEST,
    bgcolor=ft.Colors.RED,
    border_radius=ft.BorderRadius(0, 0, 10, 10),
    height=60
  )


@ft.component
def MobileSidePanel(
  workspaces, set_workspaces, active_chat_workspace, set_active_chat_workspace,
  threads, set_threads, selected_thread, set_selected_thread,
  current_view, set_current_view, on_new_workspace, on_workspace_click, 
  on_thread_click, on_settings_click, on_close
) -> ft.Control:
  """Mobile side panel that acts as a flyout menu"""
  
  return ft.Container(
    content=ft.Column([
      # Header
      ft.Container(
        content=ft.Row(
          [
            ft.Text("Menu", size=18, weight=ft.FontWeight.W_600, expand=True),
            ft.IconButton(
              icon=ft.Icons.CLOSE,
              on_click=on_close
            )
          ]
        ),
        padding=ft.padding.all(10),
        border_radius=ft.BorderRadius(0, 10, 10, 0)
      ),
      ft.Divider(),
      
      # Navigation buttons
      ft.Container(
        content=ft.Column(
          [
            SidebarButton(
              icon=ft.Icons.CHAT,
              tooltip="Threads",
              view_name="threads",
              selected_view=current_view,
              callback=lambda e: (set_current_view("threads"), on_close()),
              selectable=True
            ),
            SidebarButton(
              icon=ft.Icons.FOLDER,
              tooltip="Workspaces",
              view_name="workspaces",
              selected_view=current_view,
              callback=lambda e: (set_current_view("workspaces"), on_close()),
              selectable=True
            ),
            SidebarButton(
              icon=ft.Icons.SETTINGS,
              tooltip="Settings",
              view_name="settings",
              selected_view=current_view,
              callback=lambda e: (set_current_view("settings"), on_close()),
              selectable=True
            ),
          ],
          spacing=10
        ),
        padding=ft.padding.all(10)
      ),
      
      ft.Divider(),
      
      # Workspaces section
      ft.Container(
        content=ft.Column([
          ft.Row([
            ft.Text("Workspaces", size=12, weight=ft.FontWeight.W_500, expand=True),
            ft.IconButton(
              icon=ft.Icons.ADD,
              icon_size=18,
              on_click=lambda e: (on_new_workspace(e), on_close()),
              tooltip="New Workspace"
            )
          ]),
          *[ContextItem(ws.id, ws.name, "", lambda e, ws=ws: (on_workspace_click(ws), on_close())) for ws in workspaces]
        ], spacing=5),
        padding=ft.padding.all(10),
        expand=True,
      )
    ], spacing=0, expand=True),
    width=280,
    bgcolor=ft.Colors.SURFACE,
    expand=True
  )


@ft.component
def AppView(page: ft.Page, engine) -> ft.Control:
  """Main application view for mobile"""
  # Layout state
  current_view, set_current_view = ft.use_state("threads")
  sidebar_visible, set_sidebar_visible = ft.use_state(False)
  
  # Workspace Management State
  workspaces, set_workspaces = ft.use_state(list())
  active_chat_workspace, set_active_chat_workspace = ft.use_state(None)
  
  # Thread Management State
  threads, set_threads = ft.use_state(list())
  selected_thread, set_selected_thread = ft.use_state(None)
  messages, set_messages = ft.use_state(list())
  is_streaming, set_is_streaming = ft.use_state(False)

  # Custom drawer variables
  screen_width = page.window.width
  opacity, set_opacity = ft.use_state(0.3)
  visibility, set_visibility = ft.use_state(True)
  offset, set_offset = ft.use_state(ft.Offset(-1,0))
  shadow_offset, set_shadow_offset = ft.use_state(ft.Offset(-1,0))
  pan_direction, set_pan_direction = ft.use_state(False)

  async def handle_show_drawer():
    await page.show_drawer()

  def handle_dismissal(e: ft.Event[ft.NavigationDrawer]):
    print("Drawer dismissed!")

  async def handle_change(e: ft.Event[ft.NavigationDrawer]):
    print(f"Selected Index changed: {e.control.selected_index}")

  page.drawer = ft.NavigationDrawer(
    on_dismiss=handle_dismissal,
    on_change=handle_change,
    controls=[
      # ft.Container(height=12),
      ft.NavigationDrawerDestination(
        label="Item 1",
        icon=ft.Icons.FOLDER_OPEN_OUTLINED,
        selected_icon=ft.Icon(ft.Icons.FOLDER_OPEN),
      ),
      # ft.Divider(thickness=2),
      ft.NavigationDrawerDestination(
        icon=ft.Icon(ft.Icons.MAIL_OUTLINED),
        label="Item 2",
        selected_icon=ft.Icons.MAIL,
      ),
      ft.NavigationDrawerDestination(
        icon=ft.Icon(ft.Icons.PHONE_OUTLINED),
        label="Item 3",
        selected_icon=ft.Icons.PHONE,
      ),
    ],
  )

  # page.appbar = ft.AppBar(
  #   leading=ft.Container(
  #     IconButton(
  #       on_click=handle_show_drawer,
  #       icon=ft.Icons.MENU
  #     ),
  #     padding=ft.Padding.all(4)
  #   ),
  #   leading_width=48,
  #   # title=ft.Text("AppBar Example"),
  #   # center_title=False,
  #   # bgcolor=ft.Colors.BLUE_GREY_400,
  #   actions=[
  #     IconButton(
  #       on_click=lambda _: print("Settings"),
  #       icon=ft.Icons.SETTINGS_OUTLINED
  #     ),
  #     ft.PopupMenuButton(
  #       items=[
  #         ft.PopupMenuItem(content="Item 1"),
  #         ft.PopupMenuItem(),  # divider
  #         ft.PopupMenuItem(
  #           content="Checked item",
  #           checked=False,
  #           on_click=lambda _: print('AppBar'),
  #         ),
  #       ]
  #     ),
  #   ],
  #   toolbar_height=48
  # )
  
  async def load_workspaces():
    return
    async with engine.db.get_session() as session:
      stmt = select(Workspace)
      result = await session.execute(stmt)
      set_workspaces(result.scalars().all())
  
  async def load_threads(workspace_id=None):
    return
    async with engine.db.get_session() as session:
      if workspace_id:
        stmt = select(Thread).where(Thread.workspace_id == workspace_id)
      else:
        stmt = select(Thread)
      result = await session.execute(stmt)
      set_threads(result.scalars().all())
  
  def on_mount():
    asyncio.create_task(load_workspaces())
    asyncio.create_task(load_threads())
  
  ft.use_effect(on_mount, [])
  
  async def handle_new_workspace(e):
    set_current_view("workspaces")
  
  async def handle_workspace_click(workspace):
    set_active_chat_workspace(workspace)
    set_current_view("threads")
    await load_threads(workspace.id)
  
  async def handle_thread_click(thread):
    set_selected_thread(thread)
    set_current_view("chat")
    await load_messages(thread.id)
  
  async def load_messages(thread_id):
    async with engine.db.get_session() as session:
      stmt = select(Thread).where(Thread.id == thread_id)
      result = await session.execute(stmt)
      thread = result.scalar_one_or_none()
      if thread:
        set_messages(thread.messages)
  
  async def handle_send_message(content):
    set_is_streaming(True)
    # Handle message sending
    set_is_streaming(False)
  
  async def handle_save_workspace(name, description, ws_id=None):
    # Handle workspace save
    await load_workspaces()
  
  def toggle_drawer(e: ft.Event[ft.Button]):
    if offset.x == 0:
      set_opacity(0)
      set_offset(ft.Offset(-1, 0))
    else:
      set_shadow_offset(ft.Offset(0, 0))
      set_opacity(0.3)
      set_offset(ft.Offset(0, 0))
  
  
  # Main layout
  # main_content = ft.Column([
  #   MobileHeader(
  #     engine=engine,
  #     current_view=current_view,
  #     set_current_view=set_current_view,
  #     on_menu_click=lambda e: toggle_drawer(e)
  #     # on_menu_click=lambda e: set_sidebar_visible(not sidebar_visible)
  #     # on_menu_click=lambda e: print('hi')
  #   ),
  #   ft.Divider(height=0),
  #   # ft.Expanded(
  #   #   child=ft.Container(
  #   #     content=ft.Column([
  #   #       # Render view based on current_view
  #   #       *([ft.Text("Threads View")] if current_view == "threads" else []),
  #   #       *([ft.Text("Workspaces View")] if current_view == "workspaces" else []),
  #   #       *([ft.Text("Settings View")] if current_view == "settings" else []),
  #   #       *([ft.Text("Chat View")] if current_view == "chat" else []),
  #   #     ], expand=True),
  #   #     expand=True
  #   #   )
  #   # )
  # ], spacing=0, expand=True)
  
  # Flyout panel
  # panel = MobileSidePanel(
  #   workspaces=workspaces,
  #   set_workspaces=set_workspaces,
  #   active_chat_workspace=active_chat_workspace,
  #   set_active_chat_workspace=set_active_chat_workspace,
  #   threads=threads,
  #   set_threads=set_threads,
  #   selected_thread=selected_thread,
  #   set_selected_thread=handle_thread_click,
  #   current_view=current_view,
  #   set_current_view=set_current_view,
  #   on_new_workspace=handle_new_workspace,
  #   on_workspace_click=handle_workspace_click,
  #   on_thread_click=handle_thread_click,
  #   on_settings_click=lambda view: set_current_view(view),
  #   on_close=lambda: set_sidebar_visible(False)
  # )

  # drawer = Drawer(offset, set_offset, screen_width)
  shadow = ft.Container(
    content=ft.Column(
      expand=True,
      width=screen_width,
    ),
    expand=True,
    visible=True,
    opacity=opacity,
    offset=shadow_offset,
    on_click=toggle_drawer,
    bgcolor=ft.Colors.PRIMARY,
    animate_opacity=ft.Animation(
      duration=500,
      curve=ft.AnimationCurve.EASE_IN_OUT,
    ),
    animate_offset=ft.Animation(
      duration=1
    )
  )

  async def toggle_shadow_visibility(e):
    """ After the animation is complete switch the visibility off """
    if opacity == 0.0:
      set_shadow_offset(ft.Offset(-1,0))

  shadow.on_animation_end = toggle_shadow_visibility

  def on_pan_update(e: ft.DragUpdateEvent[ft.GestureDetector], width, offset, set_offset):
    set_pan_direction(bool(e.local_delta.x >= 0))
    new_offset = offset.x + (e.local_delta.x/(width*0.66))

    if new_offset >= 0.0:
      set_offset(ft.Offset(0, 0))
    elif new_offset <= -1.0:
      set_offset(ft.Offset(-1, 0))
    else:
      set_offset(ft.Offset(new_offset, 0))

  def on_pan_end(e: ft.DragUpdateEvent[ft.GestureDetector]):
    if pan_direction:
      set_offset(ft.Offset(0, 0))
      set_opacity(0.3)
      set_shadow_offset(ft.Offset(0, 0))
      set_pan_direction(False)
    else:
      set_offset(ft.Offset(-1, 0))
      set_opacity(0.0)
  
  return ft.Stack(
    [
      ft.Column(
        [
          # Header
          ft.Row(
            [
              IconButton(
                # on_click=lambda e: print("HI"),
                on_click=toggle_drawer,
                icon=ft.Icons.MENU
              )
            ],
            margin=ft.Margin.all(4),
          ),

          ft.Stack(
            [
              ChatWindow()
            ],
            expand=True
          )
        ]
      ),
      
      # Drawer Shadow
      shadow,

      # Sidedrawer
      ft.GestureDetector(
        ft.Row(
          [
            Drawer(
              offset,
              set_offset,
              screen_width
            )
          ]
        ),
        expand=True,
        width=screen_width,
        on_pan_end=lambda e: on_pan_end(e),
        on_pan_update=lambda e: on_pan_update(e, screen_width, offset, set_offset),
      )
    ],
    expand=True,
    margin=ft.Margin.all(0),
    alignment=ft.Alignment.TOP_LEFT
  )

async def main(page: ft.Page, engine):
  """Application window config for mobile"""
  page.padding = 0
  page.spacing = 0
  page.title = "Subconscious"
  page.bgcolor = ft.Colors.SURFACE
  page.theme_mode = ft.ThemeMode.LIGHT
  page.theme = ft.Theme(color_scheme=ft.ColorScheme(
    primary=ft.Colors.BLACK,
    secondary=ft.Colors.GREY,
    surface=ft.Colors.WHITE,
    secondary_container=ft.Colors.GREY_300,
    primary_container=ft.Colors.GREY_300
  ))
  page.dark_theme = ft.Theme(color_scheme=ft.ColorScheme(
    primary=ft.Colors.WHITE,
    secondary=ft.Colors.GREY,
    surface=ft.Colors.BLACK87,
    secondary_container=ft.Colors.GREY_800,
    primary_container=ft.Colors.GREY_800
  ))

  # Constrain the dimensions to simulate mobile screen
  page.window.width = 450
  page.window.height = 900
  page.window.min_width = 450
  page.window.max_width = 450
  page.window.min_height = 900
  page.window.max_height = 900

  return page.render(lambda: AppView(page, engine))


async def start_mobile(config):
  """Starts the mobile GUI with engine"""
  assets_path = str(pathlib.Path(__file__).parent.parent / "assets")
  logger.info(f"assets_path resolved to: {assets_path}")
  
  # engine = Engine()
  # engine = MobileEngine()
  logger.info("MobileEngine created. Starting engine...")
  # await engine.start_engine(config)
  logger.info("Engine started. Starting mobile GUI...")
  
  try:
    async def main_wrapper(page: ft.Page):
      # await main(page, engine)
      await main(page, object)
    
    logger.info("Running mobile app...")
    await ft.run_async(
      main_wrapper,
      assets_dir=assets_path
    )
  except Exception:
    logger.error("Exception in mobile app:\n" + traceback.format_exc())
    raise
  finally:
    # await engine.stop_engine()
    logger.info("Mobile app closed.")
