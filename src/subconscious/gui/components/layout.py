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
    alignment=ft.Alignment.TOP_CENTER,
    expand=True
  )

def ResponsiveItem(item, height=40, width=750) -> ft.Control:
  """ Facilitates the Responsive item """
  return ft.Row(
    [
      ft.Row(
        [
          # Unexpected behaviour if this Container is omitted
          ft.Container(
            item,
            padding=ft.padding.only(15, 0, 15, 0)
          )
        ],
        wrap=True,
        width=750,
        spacing=0
      )
    ],
    alignment=ft.MainAxisAlignment.CENTER,
    expand=True,
    wrap=True,
    spacing=0
  )
