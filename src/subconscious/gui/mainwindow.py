import asyncio
import flet as ft

from .components.buttons import TextButton
from .components.form import FormField, TextArea


@ft.component
def MainWindow(
    current_view: str = "default",
    workspace=None,
    workspace_mode="view",
    on_save_workspace=None,
    on_delete_workspace=None,
    messages=None
) -> ft.Control:
  """ The main window for the UI """
  
  # Default placeholder if no content is provided or selected
  default_content = ft.Container(
    ft.Column(
      [
        ft.Image(
          src="/logo.svg",
          width=150, height=150,
          color=ft.Colors.GREY,
        ),
        ft.Text("Subconscious", size=35, color=ft.Colors.GREY, text_align=ft.TextAlign.CENTER),
      ],
      spacing=0,
      alignment=ft.MainAxisAlignment.CENTER, horizontal_alignment=ft.CrossAxisAlignment.CENTER, expand=True
    )
  )

  # Choose content based on navigation state
  content = default_content
  if current_view == "threads":
    # Threads view usually has the chat messages here
    if messages:
        message_list = [ft.Text(f"{m.role}: {m.content}") for m in messages]
        content = ft.Container(
            content=ft.ListView(
                controls=message_list,
                spacing=10,
                padding=20,
                auto_scroll=True
            ),
            expand=True
        )
    else:
        content = ft.Container(
          content=ft.Text("Select a thread to start chatting", size=16, color=ft.Colors.GREY_500),
          alignment=ft.Alignment.CENTER,
          expand=True
        )
  elif current_view == "workspaces":
    if workspace_mode in ["create", "edit"]:
      ws_name, set_ws_name = ft.use_state(workspace.name if workspace else "")
      ws_description, set_ws_description = ft.use_state(workspace.description if workspace else "")
      
      def sync_workspace_state():
        set_ws_name(workspace.name if workspace and workspace.name else "")
        set_ws_description(workspace.description if workspace and workspace.description else "")
        
      ft.use_effect(sync_workspace_state, [workspace, workspace_mode])

      def save_ws(e):
        if on_save_workspace:
          asyncio.create_task(on_save_workspace(ws_name, ws_description, workspace.id if workspace else None))

      def delete_ws(e):
        if on_delete_workspace and workspace:
          asyncio.create_task(on_delete_workspace(workspace.id))

      content = ft.Container(
        content=ft.Column(
          [
            ft.Row([
                ft.Text(
                  "New Workspace" if workspace_mode == "create" else "Edit Workspace",
                  size=20,
                  weight=ft.FontWeight.W_500,
                  color=ft.Colors.PRIMARY,
                ),
              ],
              spacing=4,
              height=40,
            ),
            FormField(
              label="Name",
              value=ws_name,
              on_change=lambda e: set_ws_name(e.control.value),
              hint="Enter a name for your workspace"
            ),
            TextArea(
              label="Description",
              value=ws_description,
              on_change=lambda e: set_ws_description(e.control.value),
              hint="Enter a description for your workspace"
            ),
            ft.Row(
              [
                TextButton(on_click=save_ws, text="Save"),
                TextButton(on_click=delete_ws, text="Delete") if workspace_mode == "edit" else ft.Container(),
              ],
              spacing=4,
              height=40
            )
          ],
          spacing=15,
          scroll=ft.ScrollMode.AUTO, # BUG: Causes the column content to be vertically centered
        )
      )
    else:
      content = ft.Container(
        content=ft.Text("Select a workspace to view or edit", size=16, color=ft.Colors.GREY_500),
        alignment=ft.Alignment.CENTER,
        expand=True
      )
  else:
    content = default_content

  return ft.Container(
    content=content,
    padding=ft.padding.only(0, 4, 0, 4),
    expand=True,
    bgcolor=ft.Colors.SURFACE,
  )
