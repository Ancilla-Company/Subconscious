import flet as ft

from .components.buttons import IconButton


@ft.component
def Sidebar(
  on_theme_toggle,
  on_workspace_click,
  on_threads_click,
  on_context_toggle,
  selected_view="none",
) -> ft.Control:

  def SidebarIcon(icon, tooltip, view_name, callback, key=None, active=True):
    is_selected = (selected_view == view_name) if active else False
      
    return ft.Container(
      content=ft.IconButton(
        icon=icon,
        key=key,
        padding=0,
        tooltip=tooltip,
        selected=is_selected,
        on_click=callback,
        style=ft.ButtonStyle(
          shape=ft.RoundedRectangleBorder(radius=3),
          bgcolor={
            ft.ControlState.SELECTED: ft.Colors.SECONDARY_CONTAINER,
            ft.ControlState.DEFAULT: ft.Colors.TRANSPARENT,
          }
        ),
      ),
      padding=ft.padding.only(4, 4, 4, 0),
      clip_behavior=ft.ClipBehavior.HARD_EDGE,
    )

  return ft.Column(
    width=48,
    spacing=0,
    alignment=ft.MainAxisAlignment.END,
    controls=[
      ft.Container(
        expand=True,
        border=ft.border.only(right=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER)),
        content=ft.Column(
          spacing=0,
          controls=[
            SidebarIcon(ft.Icons.MENU, "Toggle Context List", "toggle", on_context_toggle, active=False),
            SidebarIcon(ft.Icons.FOLDER_OPEN_OUTLINED, "Workspaces", "workspaces", on_workspace_click),
            SidebarIcon(ft.Icons.CHAT_OUTLINED, "Threads", "threads", on_threads_click),
          ],
        ),
      ),
      ft.Container(
        padding=ft.padding.only(4, 0, 4, 4),
        border=ft.border.only(right=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER)),
        content=ft.Container(
          ft.Column(
            [
              # ft.IconButton(
              #   icon=ft.Icons.MAIL_OUTLINE_ROUNDED,
              #   tooltip="Mail",
              #   on_click=lambda _: on_theme_toggle(),
              #   style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
              # ),
              # ft.IconButton(
              #   icon=ft.Icons.CALENDAR_TODAY_ROUNDED,
              #   tooltip="Calendar",
              #   on_click=lambda _: on_theme_toggle(),
              #   style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
              # ),
              # ft.IconButton(
              #   icon=ft.Icons.CHECK_BOX_OUTLINED,
              #   tooltip="Tasks",
              #   on_click=lambda _: on_theme_toggle(),
              #   style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
              # ),
              IconButton(icon=ft.Icons.SETTINGS_OUTLINED, tooltip="Settings", on_click=(lambda _: on_theme_toggle())),
              IconButton(icon=ft.Icons.BRIGHTNESS_HIGH, tooltip="Toggle dark/light mode", on_click=(lambda _: on_theme_toggle()))
            ],
            spacing=4,
          ),
          border=ft.border.only(top=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER)),
          padding=ft.padding.only(0, 4, 0, 0),
      ))
    ]
  )
