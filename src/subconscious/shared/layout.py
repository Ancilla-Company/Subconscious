import flet as ft


# 2 Part Structure for a constrained, centre aligned, responsive layout with scrollbar positioned at the boundary
def ResponsiveParent(items) -> ft.Control:
  return ft.Container(
    ft.ListView(
      items,
      spacing=15,
      expand=True,
      auto_scroll=False,
      scroll=ft.ScrollMode.AUTO, # BUG: Causes the column content to be vertically centered
    ),
    expand=True,
    alignment=ft.Alignment.TOP_CENTER
  )

def ResponsiveItem(item, width=750) -> ft.Control:
  """ Facilitates the Responsive item """
  return ft.Row(
    [
      ft.Row(
        [
          # Unexpected behaviour if this Container is omitted
          ft.Container(
            item,
            padding=ft.padding.only(13, 0, 15, 0)
          )
        ],
        wrap=True,
        spacing=0,
        width=width,
        expand_loose=True
      )
    ],
    spacing=0,
    wrap=True,
    expand=True,
    alignment=ft.MainAxisAlignment.CENTER
  )
