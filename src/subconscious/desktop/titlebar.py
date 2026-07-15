import flet as ft


@ft.component
def TitleBar(dev: bool = False, workspace_name: str = "", model_name: str = "") -> ft.Control:
  """ Creates application title bar with drag region and window controls.
  """

  # Track maximize state locally to update tooltips/icons if needed
  is_maximized, set_is_maximized = ft.use_state(False)

  def minimize_window(e):
    e.page.window.minimized = True
    e.page.update()

  def toggle_maximize_window(e):
    e.page.window.maximized = not e.page.window.maximized
    set_is_maximized(e.page.window.maximized)
    e.page.update()

  async def close_window(e):
    await e.page.window.close()

  title_row_controls: list[ft.Control] = [
    ft.Image(
      src="/logo.svg",
      width=20,
      height=20,
      color=ft.Colors.PRIMARY,
    ),
    ft.Container(
      content=ft.Text(
        size=13,
        value="Subconscious",
        color=ft.Colors.PRIMARY
      ),
      padding=ft.padding.only(14, -4, 0, 0)
    ),
  ]

  if dev:
    title_row_controls.append(
      ft.Container(
        content=ft.Text(
          "dev",
          size=13,
          weight=ft.FontWeight.BOLD,
          text_align=ft.TextAlign.CENTER,
        ),
        bgcolor=ft.Colors.RED,
        margin=ft.margin.only(left=15),
        padding=ft.padding.only(7, 0, 7, 3),
        border_radius=ft.BorderRadius.all(3)
      )
    )

  # Spacer pushes the workspace/model indicator to the right edge of the drag area.
  title_row_controls.append(ft.Container(expand=True))

  # Workspace / model indicator — shown when either value is available.
  indicator_parts: list[ft.Control] = []
  if workspace_name:
    indicator_parts.append(
      ft.Row(
        [
          ft.Icon(ft.Icons.FOLDER_OUTLINED, size=14, color=ft.Colors.PRIMARY),
          ft.Text(workspace_name, size=13, color=ft.Colors.PRIMARY),
        ],
        spacing=5,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
      )
    )
  if workspace_name and model_name:
    indicator_parts.append(
      ft.Text("•", size=13, color=ft.Colors.PRIMARY)
    )
  if model_name:
    indicator_parts.append(
      ft.Row(
        [
          ft.Image(src="/ai_sparkle.svg", width=14, height=14, color=ft.Colors.PRIMARY),
          ft.Text(model_name, size=13, color=ft.Colors.PRIMARY),
        ],
        spacing=5,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
      )
    )

  if indicator_parts:
    title_row_controls.append(
      ft.Container(
        content=ft.Row(
          indicator_parts,
          spacing=8,
          vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        padding=ft.padding.only(0, 0, 14, 0),
      )
    )

  return ft.Container(
    ft.Row(
      spacing=0,
      height=40,
      controls=[
        ft.WindowDragArea(
          ft.GestureDetector(
            on_double_tap=toggle_maximize_window,
            content=ft.Container(
              content=ft.Row(
                title_row_controls,
                alignment=ft.MainAxisAlignment.START,
                spacing=0,
                expand=True,
              ),
              bgcolor=ft.Colors.SURFACE,
              padding=ft.padding.only(14, 10, 10, 10),
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
          border=None
        ),
      ]
    ),
    border=ft.border.only(
      bottom=ft.BorderSide(
        1,
        ft.Colors.SECONDARY_CONTAINER
      )
    )
  )
  