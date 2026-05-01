import flet as ft

from ..shared.buttons import ContextItem


@ft.component
def Drawer(offset, set_offset, width) -> ft.Control:
  """ Custom implementation of a navigation drawer
      With gesture support for sliding close, tap background close
      Open via menu button
  """
  return ft.Container(
    ft.Column(
      [
        # Header Row
        ft.Row(
          [
            # Menu
            ft.Container(
              ft.Column(
                [
                  # Context List
                  ContextItem(
                    key="workspaces",
                    name="Workspaces",
                    description=None,
                    on_click=lambda _: print()
                  ),
                  ContextItem(
                    key="threads",
                    name="Threads",
                    description=None,
                    on_click=lambda _: print(),
                  )
                ]
              ),
              expand=True,
              on_click=lambda _: None,
              bgcolor=ft.Colors.SURFACE,
              padding=ft.Padding.only(top=15, bottom=15)
            )
          ],
          spacing=0,
          expand=True
        )
      ],
      expand=True
    ),
    offset=offset,
    width=width*0.66,
    bgcolor=ft.Colors.TRANSPARENT,
    # on_click=lambda _: set_offset(ft.Offset(-1, 0)),
    animate_offset=ft.Animation(
      duration=500,
      curve=ft.AnimationCurve.EASE_IN_OUT,
    )
  )
