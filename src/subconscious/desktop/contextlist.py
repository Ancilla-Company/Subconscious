import flet as ft

from ..shared.buttons import SvgButton, ContextItem, IconButton, PopupMenuButton, Badge, WorkspacePopupItem


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
  editing_workspace=None,
  threads_list=None,
  on_new_thread=None,
  on_thread_select=None,
  selected_thread=None,
  active_chat_workspace=None,
  on_chat_workspace_change=None,
  selected_setting=None,
  set_selected_setting=None,
  show_about_badge: bool = False,
  show_all_threads: bool = False,
  on_toggle_all_threads=None
) -> ft.Control:
  """ Displays a list of items for the active view (Threads, Workspaces, Settings, etc.) """
  headers = []

  if current_context == "threads":
    title_text = "Threads"
    list_items = []
    if threads_list:
      for thread in threads_list:
        is_selected = selected_thread and thread.id == selected_thread.id
        list_items.append(
          ContextItem(
            key=thread.id,
            name=thread.title if thread.title else "Untitled Thread",
            description=thread.description,
            updated_at=thread.updated_at,
            on_click=lambda _, t=thread: on_thread_select(t) if on_thread_select else None,
            selected=is_selected
          )
        )
    else:
      list_items = [
        ft.Container(
          content=ft.Text("No threads found.", size=14, color=ft.Colors.GREY_600),
          padding=ft.padding.only(15, 0, 13, 0)
        )
      ]

    headers = [
      SvgButton(on_click=on_new_thread if on_new_thread else None, svg_path="/new_thread.svg", tooltip="New Thread"),
      PopupMenuButton(
        icon=ft.Icons.FOLDER_OPEN_OUTLINED,
        tooltip="Switch Workspace",
        menu_items=[
          WorkspacePopupItem(
            name=ws.name,
            switch_workspace=lambda _, w=ws: on_chat_workspace_change(w) if on_chat_workspace_change else None,
            slug=ws.id,
            active=bool(not show_all_threads and active_chat_workspace and ws.id == active_chat_workspace.id)
          ) for ws in (workspaces_list or [])
        ] + [
          ft.PopupMenuItem(),  # divider
          ft.PopupMenuItem(
            content=ft.Row(
              [
                ft.Icon(
                  ft.Icons.CHECK if show_all_threads else ft.Icons.CHECK,
                  size=16,
                  color=ft.Colors.PRIMARY if show_all_threads else ft.Colors.TRANSPARENT,
                ),
                ft.Text("All Workspaces"),
              ],
              spacing=8
            ),
            on_click=lambda _: on_toggle_all_threads(not show_all_threads),
          )
        ]
      )
    ]

  elif current_context == "workspaces":
    title_text = "Workspaces"
    list_items = []
    if workspaces_list:
      for ws in workspaces_list:
        is_selected = editing_workspace and ws.id == editing_workspace.id
        list_items.append(
          ContextItem(
            key=ws.id,
            name=ws.name,
            description=ws.description,
            updated_at=ws.created_at,
            on_click=lambda _, w=ws: on_workspace_selected_for_edit(w),
            selected=is_selected
          )
        )
    else:
      list_items = [
        ft.Container(
          content=ft.Text("No workspaces found.", size=14, color=ft.Colors.GREY_600),
          padding=ft.padding.only(15, 0, 13, 0)
        )
      ]

    headers = [IconButton(icon=ft.Icons.ADD, tooltip="New Workspace", on_click=on_new_workspace)]

  elif current_context == "settings":
    title_text = "Settings"
    list_items = [
      ContextItem(
        key="general",
        name="General",
        description="App settings and preferences",
        on_click=lambda _: set_selected_setting("general"),
        selected=selected_setting == "general"
      ),
      ContextItem(
        key="models",
        name="Models",
        description="Configure LLMs and API keys",
        on_click=lambda _: set_selected_setting("models"),
        selected=selected_setting == "models"
      ),
      ContextItem(
        key="tools",
        name="Tools",
        description="Configure Tools",
        on_click=lambda _: set_selected_setting("tools"),
        selected=selected_setting == "tools"
      ),
      ContextItem(
        key="skills",
        name="Skills",
        description="Configure Skills",
        on_click=lambda _: set_selected_setting("skills"),
        selected=selected_setting == "skills"
      ),
      ContextItem(
        key="about",
        name="About",
        description="About Subconscious",
        on_click=lambda _: set_selected_setting("about"),
        selected=selected_setting == "about",
        badge=Badge() if show_about_badge else None
      )
    ]
    headers = []

  else:
    title_text = "No Activity Selected"
    list_items = [
      ft.Container(
        content=ft.Text("Select an activity from the sidebar", size=14, color=ft.Colors.GREY_600),
        padding=ft.padding.only(15, 0, 13, 0)
      )
    ]

  return ft.Container(
    visible=visible,
    width=width,
    bgcolor=ft.Colors.SURFACE,
    padding=ft.padding.only(0, 4, 0, 4),
    content=ft.Column([
      # Header
      ft.Container(
        content=ft.Row(
          [
            ft.Text(
              title_text,
              size=20,
              weight=ft.FontWeight.W_500,
              color=ft.Colors.PRIMARY,
              expand=True,
            ),
            *headers
          ],
          spacing=4,
          height=40
        ),
        padding=ft.padding.only(15, 0, 13, 0)
      ),
      
      # List container
      ft.Container(
        expand=True,
        content=ft.ListView(
          expand=True,
          spacing=4,
          controls=list_items,
        ),
      ),
    ], spacing=4),
  )
