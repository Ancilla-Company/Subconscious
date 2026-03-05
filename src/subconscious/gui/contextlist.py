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

# def context_toggle()

@ft.component
def ContextList(
  visible: bool = True,
  width: int = 380,
  current_view: str = "none",
  current_context: str = "none",
  on_workspace_select=None,
  workspaces_list=None,
  on_new_workspace=None,
  on_workspace_selected_for_edit=None,
  selected_workspace=None,
  threads_list=None,
  on_thread_select=None,
  selected_thread=None
) -> ft.Control:
  """ Displays a list of items for the active view (Threads, Workspaces, etc.) """
  
  # Ensure the selected state is reflected in the UI
  # This use_effect might be redundant if the parent component re-renders correctly, 
  # but user specifically asked for it to ensure updates.
  # ft.use_effect(lambda: None, [selected_workspace, selected_thread, workspaces_list, threads_list])

  headers = []

  if current_context == "threads":
    title_text = "Latest Threads"
    list_items = []
    if threads_list:
        for thread in threads_list:
            is_selected = selected_thread and thread.id == selected_thread.id
            list_items.append(
                ContextItem(
                    key=thread.id,
                    name=thread.title if thread.title else "Untitled Thread",
                    description=thread.description if thread.description else "No description",
                    updated_at=thread.created_at,
                    on_click=lambda _, t=thread: on_thread_select(t) if on_thread_select else None,
                    selected=is_selected
                )
            )
    else:
        list_items = [ft.Text("No threads found.", size=14, color=ft.Colors.GREY_600)]

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

  elif current_context == "workspaces":
    title_text = "Workspaces"
    list_items = []
    if workspaces_list:
      for ws in workspaces_list:
        is_selected = selected_workspace and ws.id == selected_workspace.id
        list_items.append(
          ContextItem(
            key=ws.id,
            name=ws.name,
            description=ws.description,
            updated_at=ws.created_at,
            on_click=lambda _: on_workspace_selected_for_edit(ws),
            selected=is_selected
          )
        )
    else:
      list_items = [ft.Text("No workspaces found.", size=14, color=ft.Colors.GREY_600)]

    headers = [IconButton(icon=ft.Icons.ADD, tooltip="New Workspace", on_click=on_new_workspace)]

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
