import pathlib
import flet as ft
from dataclasses import dataclass, field

from ..gui.sidebar import Sidebar
from ..gui.titlebar import TitleBar
from ..gui.frame import Frame
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
def UserView(user: User, delete_user) -> ft.Control:
  # Local (transient) editing state—NOT in User
  is_editing, set_is_editing = ft.use_state(False)
  new_first_name, set_new_first_name = ft.use_state(user.first_name)
  new_last_name, set_new_last_name = ft.use_state(user.last_name)

  def start_edit():
    set_new_first_name(user.first_name)
    set_new_last_name(user.last_name)
    set_is_editing(True)

  def save():
    user.update(new_first_name, new_last_name)
    set_is_editing(False)

  def cancel():
    set_is_editing(False)

  if not is_editing:
    return ft.Row(
      [
        ft.Text(f"{user.first_name} {user.last_name}"),
        ft.Button("Edit", on_click=start_edit),
        ft.Button("Delete", on_click=lambda: delete_user(user)),
      ]
    )

  return ft.Row(
    [
      ft.TextField(
        label="First Name",
        value=new_first_name,
        on_change=lambda e: set_new_first_name(e.control.value),
        width=180,
      ),
      ft.TextField(
        label="Last Name",
        value=new_last_name,
        on_change=lambda e: set_new_last_name(e.control.value),
        width=180,
      ),
      ft.Button("Save", on_click=save),
      ft.Button("Cancel", on_click=cancel),
    ]
  )


@ft.component
def AddUserForm(add_user) -> ft.Control:
  # Uses local buffers; calls parent action on Add
  new_first_name, set_new_first_name = ft.use_state("")
  new_last_name, set_new_last_name = ft.use_state("")

  def add_user_and_clear():
    add_user(new_first_name, new_last_name)
    set_new_first_name("")
    set_new_last_name("")

  return ft.Row(
    controls=[
      ft.TextField(
        label="First Name",
        width=200,
        value=new_first_name,
        on_change=lambda e: set_new_first_name(e.control.value),
      ),
      ft.TextField(
        label="Last Name",
        width=200,
        value=new_last_name,
        on_change=lambda e: set_new_last_name(e.control.value),
      ),
      ft.Button("Add", on_click=add_user_and_clear),
    ]
  )




@ft.component
def AppView(page: ft.Page) -> list[ft.Control]:
  # Layout state
  context_visible, set_context_visible = ft.use_state(False)
  context_width, set_context_width = ft.use_state(380)
  current_view, set_current_view = ft.use_state("none")
  
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

async def main(page: ft.Page):
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
  return page.render(lambda: AppView(page))

async def start_gui(config):
  """ Starts the GUI engine """
  assets_path = str(pathlib.Path(__file__).parent.parent / "assets")
  await ft.run_async(main, assets_dir=assets_path)
