import flet as ft


@ft.component
def Frame(
  sidebar: ft.Control,
  contextlist: ft.Control,
  mainwindow: ft.Control,
  context_visible: bool = True,
  on_context_width_change = None,
  workspace_name: str = "General"
) -> ft.Control:
  """ Main application frame that organizes components with an adjustable divider """
  
  def move_vertical_divider(e: ft.DragUpdateEvent):
    # Pass the delta_x to the parent to handle context list width change
    if on_context_width_change:
      on_context_width_change(e.local_delta.x*3)

  # Create divider component
  divider = ft.GestureDetector(
    visible=context_visible,
    content=ft.VerticalDivider(width=5, color=ft.Colors.SECONDARY_CONTAINER),
    drag_interval=10,
    on_pan_update=move_vertical_divider,
    mouse_cursor=ft.MouseCursor.RESIZE_LEFT_RIGHT,
  )

  return ft.Container(
    expand=True,
    bgcolor=ft.Colors.SURFACE,
    content=ft.Row([
      sidebar,
      ft.Container(
        expand=True,
        content=ft.Column([
          # Main region
          ft.Row([
            contextlist,
            divider,
            mainwindow
          ], spacing=0, expand=True),
          
          # Footer - Status Bar
          ft.Row([
            ft.Container(
              expand=True,
              height=20,
              bgcolor=ft.Colors.SURFACE,
              alignment=ft.Alignment.CENTER_RIGHT,
              padding=ft.padding.only(5, 0, 5, 0),
              border=ft.border.only(top=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER)),
              content=ft.Row([
                ft.Text(f"Workspace: {workspace_name}", size=10, color=ft.Colors.GREY_600),
                ft.VerticalDivider(width=1, color=ft.Colors.SECONDARY_CONTAINER),
                ft.Text("Version 0.1.0  ", size=10, color=ft.Colors.GREY_600),
              ], alignment=ft.MainAxisAlignment.END, spacing=10),
            ),
          ], spacing=0, height=20)
        ], spacing=0, expand=True),
      )
    ], spacing=0)
  )