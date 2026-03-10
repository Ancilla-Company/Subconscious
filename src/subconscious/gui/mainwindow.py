import asyncio
import flet as ft

from .screens.chat import ChatWindow
from .screens.settings import General
from .components.buttons import TextButton
from .components.forms import FormField, TextArea, CheckBox
from .components.layout import ResponsiveItem, ResponsiveParent


@ft.component
def MainWindow(
    current_view: str = "default",
    workspace=None,
    workspace_mode="view",
    settings_mode="general",
    on_save_workspace=None,
    on_delete_workspace=None,
    thread=None,
    messages=None,
    on_send_message=None,
    settings=None,
    on_setting_change=None
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
    content = ft.Container(
      content=ChatWindow(
        thread=thread,
        messages=messages,
        on_send_message=on_send_message
      )
    )
  elif current_view == "settings":
    if settings_mode == "general":
      content = General(settings=settings, on_setting_change=on_setting_change)
    elif settings_mode == "models":
      content = ft.Container(
        content=ft.Text("Model Settings (Work in Progress)", size=16, color=ft.Colors.GREY_500),
        alignment=ft.Alignment.CENTER,
        expand=True
      )
    else:
      content = ft.Container(
        content=ft.Text("Select a settings category", size=16, color=ft.Colors.GREY_500),
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
        content=ResponsiveParent(
          [
            ResponsiveItem(
              ft.Container(
                ft.Text(
                  "New Workspace" if workspace_mode == "create" else "Edit Workspace",
                  size=20,
                  weight=ft.FontWeight.W_500,
                  color=ft.Colors.PRIMARY,
                  expand=True
                ),
                height=40,
                padding=ft.padding.only(0, 6, 0 , 0),
                margin=ft.margin.only(0, 4, 0, 4)
              )
            ),
            ResponsiveItem(
              FormField(
                label="Name",
                value=ws_name,
                on_change=lambda e: set_ws_name(e.control.value),
                hint="Enter a name for your workspace"
              )
            ),
            ResponsiveItem(
              TextArea(
                label="Description",
                value=ws_description,
                on_change=lambda e: set_ws_description(e.control.value),
                hint="Enter a description for your workspace"
              )
            ),
            ResponsiveItem(
              ft.Row(
                [
                  TextButton(on_click=save_ws, text="Save"),
                  TextButton(on_click=delete_ws, text="Delete") if workspace_mode == "edit" else ft.Container(),
                ],
                wrap=True,
                spacing=4
              ),
            )
          ]
        ),
        expand=True
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
    padding=ft.padding.only(0, 0, 0, 0),
    expand=True,
    bgcolor=ft.Colors.SURFACE,
  )
