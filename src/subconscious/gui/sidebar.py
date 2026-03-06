import flet as ft

from .components.buttons import IconButton, SidebarButton


@ft.component
def Sidebar(
  on_theme_toggle,
  on_workspace_click,
  on_threads_click,
  on_context_toggle,
  on_settings_click,
  selected_view="none",
) -> ft.Control:

  return ft.Column(
    width=48,
    spacing=0,
    alignment=ft.MainAxisAlignment.END,
    controls=[
      ft.Container(
        expand=True,
        padding=ft.padding.only(4, 4, 4, 4),
        border=ft.border.only(right=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER)),
        content=ft.Column(
          spacing=4,
          controls=[
            SidebarButton(ft.Icons.MENU, "Toggle Context List", "toggle", selected_view, on_context_toggle, active=False),
            SidebarButton(ft.Icons.FOLDER_OPEN_OUTLINED, "Workspaces", "workspaces", selected_view, on_workspace_click),
            SidebarButton(ft.Icons.CHAT_OUTLINED, "Threads", "threads", selected_view, on_threads_click),
          ],
        ),
      ),
      ft.Container(
        padding=ft.padding.only(4, 0, 4, 4),
        border=ft.border.only(right=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER)),
        content=ft.Container(
          ft.Column(
            [
              SidebarButton(ft.Icons.SETTINGS_OUTLINED, "Settings", "settings", selected_view, on_settings_click),
              IconButton(icon=ft.Icons.BRIGHTNESS_HIGH, tooltip="Toggle dark/light mode", on_click=on_theme_toggle)
            ],
            spacing=4,
          ),
          border=ft.border.only(top=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER)),
          padding=ft.padding.only(0, 4, 0, 0),
      ))
    ]
  )
