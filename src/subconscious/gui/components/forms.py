import flet as ft


def FormField(label, value, on_change, hint) -> ft.Control:
  """ Form field formatted to the application's style language """
  return ft.Column(
      [
        ft.Container(
          content=ft.Text(
            label,
            size=15,
            color=ft.Colors.PRIMARY,
          ),
          height=25
        ),
        ft.Container(content=
          ft.TextField(
            value=value,
            on_change=on_change,
            border=ft.InputBorder.NONE,
            border_color=ft.Colors.TRANSPARENT,
            bgcolor=ft.Colors.TRANSPARENT,
            border_radius=3,
            multiline=False, 
            clip_behavior=ft.ClipBehavior.HARD_EDGE, 
            content_padding=ft.padding.only(10, -10, 2, 2),
            hint_text=hint,
            hint_style=ft.TextStyle(color=ft.Colors.SECONDARY, weight=ft.FontWeight.NORMAL),
            expand=True
          ),
          border=ft.border.all(1, ft.Colors.PRIMARY),
          padding=ft.padding.only(0, 0, 0, 0),
          border_radius=3,
          margin=ft.margin.all(0),
          bgcolor=ft.Colors.SURFACE,
          expand=True,
          height=40,
          clip_behavior=ft.ClipBehavior.HARD_EDGE,
        )
      ],
      spacing=0,
    )

def TextArea(label, value, on_change, hint, lines=10) -> ft.Control:
  """ Text Area formatted to the application's style language """
  return ft.Column(
      [
        ft.Container(
          content=ft.Text(
            label,
            size=15,
            color=ft.Colors.PRIMARY,
          ),
          height=25
        ),
        ft.Container(content=
          ft.TextField(
            value=value,
            on_change=on_change,
            border=ft.InputBorder.NONE,
            border_color=ft.Colors.TRANSPARENT,
            bgcolor=ft.Colors.TRANSPARENT,
            border_radius=3,
            multiline=True,
            min_lines=lines,
            max_lines=lines, 
            clip_behavior=ft.ClipBehavior.HARD_EDGE, 
            content_padding=ft.padding.only(10, 10, 0, 10),
            hint_text=hint,
            hint_style=ft.TextStyle(color=ft.Colors.SECONDARY, weight=ft.FontWeight.NORMAL),
            expand=True
          ),
          border=ft.border.all(1, ft.Colors.PRIMARY),
          border_radius=3,
          margin=ft.margin.all(0),
          bgcolor=ft.Colors.SURFACE,
          expand=True,
          clip_behavior=ft.ClipBehavior.HARD_EDGE,
        )
      ],
      spacing=0,
    )

def CheckBox(label, value, on_change) -> ft.Control:
  """ Checkbox formatted to the application's styling """
  return ft.Row([
    ft.Checkbox(
      label=label,
      # data=(title, key, val),
      value=value, on_change=on_change,
      shape=ft.RoundedRectangleBorder(radius=3),
      label_style=ft.TextStyle(size=15, overflow=ft.TextOverflow.CLIP), tooltip=label, expand_loose=True
    ),
  ], spacing=0, wrap=True)