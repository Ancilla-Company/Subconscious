import flet as ft


@ft.component
def TitleBar() -> ft.Control:
  """ Creates application title bar with drag region and window controls """

  # Track maximize state locally to update tooltips/icons if needed
  is_maximized, set_is_maximized = ft.use_state(False)

  def minimize_window(e):
    e.page.window.minimized = True
    e.page.update()

  def toggle_maximize_window(e):
    e.page.window.maximized = not e.page.window.maximized
    set_is_maximized(e.page.window.maximized)
    e.page.update()

  def close_window(e):
    e.page.window.close()

  return ft.Container( ft.Row(
    spacing=0,
    height=40,
    controls=[
      ft.WindowDragArea(
        ft.GestureDetector(
          on_double_tap=toggle_maximize_window,
          content=ft.Container(
            content=ft.Row([
              ft.Image(
                src="/logo.svg",
                width=20, height=20,
                color=ft.Colors.PRIMARY,
              ),
              ft.Container(
                content=ft.Text(
                  "Subconscious",
                  size=13, color=ft.Colors.PRIMARY
                ),
                padding=ft.padding.only(14, -4, 0, 0)
              ),
            ], alignment=ft.MainAxisAlignment.START, spacing=0, expand=True),
            bgcolor=ft.Colors.SURFACE,
            padding=ft.padding.only(14, 10, 10, 10),
            # border=ft.border.only(bottom=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER))
          ),
        ),
        expand=True,
      ),
      ft.Container(
        content=ft.Row([
          ft.FilledButton(
            content=ft.Image(
              src="/minimize.svg",
              width=12, height=12,
              color=ft.Colors.ON_SURFACE,
            ),
            on_click=minimize_window,
            style=ft.ButtonStyle(
              shape=ft.RoundedRectangleBorder(side=None, radius=0),
              shadow_color=ft.Colors.TRANSPARENT,
              bgcolor=ft.Colors.SURFACE,
              padding=ft.padding.only(14, 14, 14, 14),
              overlay_color=ft.Colors.SECONDARY_CONTAINER
            ),
            width=40, height=40, tooltip="Minimize"
          ),
          ft.FilledButton(
            content=ft.Image(
              src="/restore.svg" if is_maximized else "/maximize.svg",
              width=12, height=12,
              color=ft.Colors.ON_SURFACE,
            ),
            on_click=toggle_maximize_window,
            style=ft.ButtonStyle(
              shape=ft.RoundedRectangleBorder(side=None, radius=0),
              shadow_color=ft.Colors.TRANSPARENT,
              bgcolor=ft.Colors.SURFACE,
              padding=ft.padding.only(14, 14, 14, 14),
              overlay_color=ft.Colors.SECONDARY_CONTAINER
            ),
            width=40, height=40,
            tooltip="Restore" if is_maximized else "Maximize"
          ),
          ft.FilledButton(
            content=ft.Image(
              src="/close.svg",
              width=12, height=12,
              color=ft.Colors.ON_SURFACE,
            ),
            on_click=close_window,
            style=ft.ButtonStyle(
              shape=ft.RoundedRectangleBorder(radius=0),
              shadow_color=ft.Colors.TRANSPARENT,
              bgcolor=ft.Colors.SURFACE,
              padding=ft.padding.only(14, 14, 14, 14),
              overlay_color=ft.Colors.RED
            ),
            width=40, height=40, tooltip="Close",
          ),
        ], spacing=0),
        # border=ft.border.only(bottom=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER))
        border=None
      ),
    ]
  ),
  border=ft.border.only(bottom=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER))
  )
  