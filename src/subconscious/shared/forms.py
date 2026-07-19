import flet as ft


def FormField(label, value, on_change, hint, visible=True) -> ft.Control:
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
            hint_style=ft.TextStyle(
              color=ft.Colors.SECONDARY,
              weight=ft.FontWeight.NORMAL
            ),
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
      visible=visible
    )

def PasswordField(label, value, on_change, hint, visible=True) -> ft.Control:
  """ Password field formatted to the application's style language """
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
            password=True,
            can_reveal_password=True,
            multiline=False, 
            clip_behavior=ft.ClipBehavior.HARD_EDGE, 
            content_padding=ft.padding.only(10, 5, 2, 2),
            hint_text=hint,
            hint_style=ft.TextStyle(
              color=ft.Colors.SECONDARY,
              weight=ft.FontWeight.NORMAL
            ),
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
      visible=visible
    )

@ft.component
def DropdownField(label, values, on_change, hint, value=None) -> ft.Control:
  """ Dropdown field formatted to the application's style language """
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
          ft.Dropdown(
            value=value,
            on_select=on_change,
            border_color=ft.Colors.TRANSPARENT,
            border_radius=3,
            content_padding=ft.padding.only(10, 5, 2, 2),
            hint_text=hint,
            hint_style=ft.TextStyle(
              color=ft.Colors.SECONDARY,
              weight=ft.FontWeight.NORMAL
            ),
            expand=True,
            dense=True,
            options=values,
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
      label_style=ft.TextStyle(
        size=15,
        overflow=ft.TextOverflow.CLIP
      ),
       tooltip=label,
       expand_loose=True
    ),
  ],
  spacing=0,
  wrap=True
)

def ExpansionTile(label, on_change) -> ft.Control:
  """ Expansion tile for hiding long vertical forms """
  # the built-in / custom tool tiles.
  tile = ft.ExpansionTile(
    min_tile_height=36,
    title=ft.Container(
      content=ft.Column(
        [
          ft.Text(
            size=15,
            value="Installed Skills"
          )
        ],
        spacing=0,
      ),
      padding=ft.Padding.only(top=-2, bottom=-2)
    ),
    dense=True,
    expand=True,
    expanded=False,
    controls=[body],
    visual_density=ft.VisualDensity.COMPACT
  )

  return ft.Column(
    [
      ft.Container(
        height=25,
        content=ft.Text(
          size=15,
          value="Skills",
          color=ft.Colors.PRIMARY
        ),
      ),
      ft.Container(
        ft.Column(
          spacing=0,
          controls=[skills_tile]
        ),
        border_radius=3,
        margin=ft.Margin.all(0),
        padding=ft.Padding.all(0),
        border=ft.border.all(1, ft.Colors.PRIMARY)
      ),
    ],
    spacing=0,
    scroll=ft.ScrollMode.ADAPTIVE
  )

def Switch(disabled, value, tooltip, label, on_change=None) -> ft.Control:
  """ Platform styled switch """
  return ft.Switch(
    height=30,
    value=value,
    on_change=None,
    tooltip=tooltip,
    disabled=disabled,
    label=ft.Text(label, size=20, expand=True)
  )
