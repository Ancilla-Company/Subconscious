import flet as ft
from datetime import datetime

from .components.buttons import SvgButton, ContextItem, IconButton, PopupMenuButton


class WorkspacePopupItem(ft.PopupMenuItem):
  def __init__(self, name, switch_workspace, slug):
    super().__init__()
    self.switch_workspace = switch_workspace
    self.name = name
    self.content = ft.Row(
      controls=[
        ft.Text(name),
      ],
    )
    self.data = slug
    self.on_click = switch_workspace
  
  # async def update_settings(self, event):
  #   event.data = self.data
  #   self.scm(self.name)
  #   await SettingsQueue.put((self.switch_llm, (event,), {}))

@ft.component
def ContextList(
  visible: bool = True,
  width: int = 380,
  current_view: str = "threads",
  on_workspace_select=None
) -> ft.Control:
  """ Displays a list of items for the active view (Threads, Workspaces, etc.) """
  headers = []

  if current_view == "threads":
    title_text = "Latest Threads"
    list_items = [
      ContextItem(
        name="Welcome Thread",
        description="Initial chat setup...",
        updated_at=datetime.now(),
        on_click=lambda _: print("Thread selected")
      )
    ]
    headers = [
      SvgButton(on_click=lambda _: print("New thread clicked"), svg_path="/new_thread.svg", tooltip="New Thread"),
      PopupMenuButton(
        icon=ft.Icons.FOLDER_OPEN_OUTLINED,
        tooltip="Switch Workspace",
        menu_items=[
          WorkspacePopupItem(name="General", switch_workspace=lambda _: on_workspace_select() if on_workspace_select else print("Switching to General workspace"), slug="general")
        ]
      )
    ]

  elif current_view == "workspaces":
    title_text = "Workspaces"
    list_items = [
      ContextItem(
        name="General",
        description="Default workspace for all threads.",
        updated_at=datetime.now(),
        on_click=lambda _: on_workspace_select() if on_workspace_select else print("Workspace selected")
      )
    ]
    headers = [IconButton(icon=ft.Icons.ADD, tooltip="New Workspace", on_click=lambda _: print("New workspace clicked"))]

  else:
    title_text = "No Activity Selected"
    list_items = [ft.Text("Select an activity from the sidebar", size=14, color=ft.Colors.GREY_600)]

  return ft.Container(
    visible=visible,
    width=width,
    bgcolor=ft.Colors.SURFACE,
    content=ft.Column([
      # Header
      ft.Container(
        padding=ft.padding.only(15, 4, 15, 4),
        content=ft.Row([
          ft.Text(
            title_text,
            size=20,
            weight=ft.FontWeight.W_500,
            color=ft.Colors.PRIMARY,
            expand=True,
          ),
          *headers
        ], spacing=4),
      ),
      
      # List container
      ft.Container(
        expand=True,
        content=ft.ListView(
          expand=True,
          spacing=4,
          padding=ft.padding.only(14, 0, 14, 4),
          controls=list_items,
        ),
      ),
    ], spacing=0),
  )
