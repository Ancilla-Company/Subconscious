import pathlib
import flet as ft
from dataclasses import dataclass, field

from ..engine import Engine
from ..gui.frame import Frame
from ..gui.sidebar import Sidebar
from ..gui.titlebar import TitleBar
from ..gui.contextlist import ContextList
from ..gui.mainwindow import MainWindow


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
  
  def toggle_context():
    set_context_visible(not context_visible)
    
  def handle_context_width_change(delta_x):
    new_width = context_width + delta_x
    if 200 <= new_width <= 700:
      set_context_width(new_width)

  def toggle_theme():
    page.theme_mode = (
      ft.ThemeMode.DARK if page.theme_mode == ft.ThemeMode.LIGHT else ft.ThemeMode.LIGHT
    )
    page.update()

  def switch_to_workspace():
    set_current_view("workspaces")
    set_context_visible(True)

  def switch_to_threads():
    set_current_view("threads")
    set_context_visible(True)

  return [
    TitleBar(),
    Frame(
      sidebar=Sidebar(
        on_theme_toggle=toggle_theme,
        on_workspace_click=switch_to_workspace,
        on_threads_click=switch_to_threads,
        on_context_toggle=toggle_context,
        selected_view=current_view
      ),
      contextlist=ContextList(
        visible=context_visible,
        width=context_width,
        current_view=current_view,
        on_workspace_select=switch_to_threads
      ),
      mainwindow=MainWindow(
        current_view=current_view
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
