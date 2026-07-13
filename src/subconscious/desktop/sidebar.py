import flet as ft

from ..shared.buttons import IconButton, SidebarButton, Avatar, Badge

@ft.component
def Sidebar(
  on_workspace_click,
  on_threads_click,
  on_context_toggle,
  on_settings_click,
  on_account_click,
  config,
  selected_view="none",
  show_settings_badge: bool = False,
  on_notifications_click=None,
  active_jobs: int = 0,
  # Seed for the identicon — pass a username or UUID once accounts exist.
  # Defaults to a fixed string so the avatar is stable before login.
  avatar_seed: str = "subconscious-default-user",
) -> ft.Control:
  # Set personal icons
  personal_list = [
    SidebarButton(
      ft.Icons.NOTIFICATIONS_NONE_OUTLINED,
      "Background Jobs",
      "notifications",
      selected_view,
      on_notifications_click,
      selectable=False,
      badge=ft.Badge(text=str(active_jobs)) if active_jobs > 0 else None,
    ),
    SidebarButton(
      ft.Icons.SETTINGS_OUTLINED,
      "Settings",
      "settings",
      selected_view,
      on_settings_click,
      badge=ft.Badge() if show_settings_badge else None,
    ),
  ]

  if config.dev:
    personal_list.append(
      Avatar(
        seed=avatar_seed,
        tooltip="Account",
        view_name="account",
        selected_view=selected_view,
        callback=on_account_click,
      )
    )
  
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
            SidebarButton(ft.Icons.MENU, "Toggle Context List", "toggle", selected_view, on_context_toggle, selectable=False),
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
            personal_list,
            spacing=4,
          ),
          border=ft.border.only(top=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER)),
          padding=ft.padding.only(0, 4, 0, 0),
      ))
    ]
  )
