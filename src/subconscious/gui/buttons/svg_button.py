import flet as ft


@ft.component
def SvgButton(on_click, svg_path, tooltip=None) -> ft.Control:
  """ A button component that displays an SVG icon for when built in icons don't fit the use case. """
  return ft.Container(
    ft.Container(
      content=ft.Stack([
          ft.Image(
            src=svg_path,
            width=24, height=24,
            top=8, left=8,
            color=ft.Colors.PRIMARY
          ),
          ft.TextButton(on_click=on_click, style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)), width=40, height=40),
        ], clip_behavior=ft.ClipBehavior.HARD_EDGE,
        width=40, height=40
      ),
      padding=ft.padding.only(0,0,0,0),
      shape=ft.RoundedRectangleBorder(radius=3),
    ),
    border_radius=ft.BorderRadius(3,3,3,3), visible=True,
  )
