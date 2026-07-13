import flet as ft
from datetime import datetime

from .identicon import identicon


@ft.component
def SidebarButton(icon, tooltip, view_name, selected_view, callback, key=None, selectable=True, badge=None):
  is_selected = (selected_view == view_name) if selectable else False

  return ft.Container(
    content=ft.IconButton(
      icon=icon,
      key=key,
      padding=0,
      tooltip=tooltip,
      selected=is_selected,
      on_click=callback,
      style=ft.ButtonStyle(
        shape=ft.RoundedRectangleBorder(radius=3),
        bgcolor={
          ft.ControlState.SELECTED: ft.Colors.SECONDARY_CONTAINER,
          ft.ControlState.DEFAULT: ft.Colors.TRANSPARENT,
        }
      ),
      badge=badge,
    ),
    clip_behavior=ft.ClipBehavior.HARD_EDGE,
  )


@ft.component
def Avatar(seed: str, tooltip: str, view_name: str, selected_view: str, callback):
  """ A SidebarButton variant that displays a GitHub-style identicon avatar
      instead of an icon. The identicon is generated deterministically from
      ``seed`` (e.g. a username or UUID) so it is stable across sessions.
  """
  is_selected = selected_view == view_name

  return ft.Container(
    content=ft.Image(
      src=identicon(seed, size=40),
      tooltip=tooltip,
      height=40,
      width=40,
    ),
    ink=True,
    width=40,
    height=40,
    border_radius=3,
    border=ft.border.all(1, ft.Colors.SECONDARY) if is_selected else ft.border.all(1, ft.Colors.OUTLINE_VARIANT),
    tooltip=tooltip,
    on_click=callback,
    clip_behavior=ft.ClipBehavior.HARD_EDGE,
    bgcolor=ft.Colors.SECONDARY_CONTAINER if is_selected else ft.Colors.SURFACE_CONTAINER,
  )


class WorkspacePopupItem(ft.PopupMenuItem):
  """ Popup Item for popup menu """
  def __init__(self, name, switch_workspace, slug, active=False):
    super().__init__()
    self.switch_workspace = switch_workspace
    self.name = name
    self.content = ft.Row(
      controls=[
        ft.Icon(
          ft.Icons.CHECK,
          size=16,
          color=ft.Colors.PRIMARY if active else ft.Colors.TRANSPARENT,
        ),
        ft.Text(name),
      ],
      spacing=8,
    )
    self.data = slug
    self.on_click = switch_workspace

@ft.component
def SvgButton(on_click, svg_path, tooltip=None) -> ft.Control:
  """ A button component that displays an SVG icon for when built in icons don't fit the use case. """
  return ft.Container(
    ft.Container(
      content=ft.Stack(
        [
          ft.Image( # Causes an error if the image is put in the TextButton
            src=svg_path,
            width=24, height=24,
            top=8, left=8,
            color=ft.Colors.PRIMARY
          ),
          ft.TextButton(
            on_click=on_click,
            style=ft.ButtonStyle(
              shape=ft.RoundedRectangleBorder(radius=3)
            ),
            width=40,
            height=40
          ),
        ],
        clip_behavior=ft.ClipBehavior.HARD_EDGE,
        width=40,
        height=40
      ),
      padding=ft.padding.only(0,0,0,0),
      shape=ft.RoundedRectangleBorder(radius=3),
    ),
    border_radius=ft.BorderRadius(3,3,3,3), visible=True,
  )

@ft.component
def IconButton(on_click, icon, icon_colour=None, tooltip=None) -> ft.Control:
  """ A button component that displays a built in icon. """
  return ft.IconButton(
    icon=icon,
    tooltip=tooltip,
    on_click=on_click,
    icon_color=icon_colour,
    style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
  )

def ContextItem(key, name, description, on_click, updated_at=None, selected=False, badge=None) -> ft.Control:
  
  async def handle_click(e):
    await on_click(e)
  
  def render_time():
    """ Returns a human readable time string, adjusted for how long ago the message was sent. """
    if updated_at is None: return ""
    
    now = datetime.now()
    diff = now - updated_at

    if diff.days == 0:
      return updated_at.strftime("%H:%M")
    elif diff.days == 1:
      return "Yesterday"
    elif diff.days < 7:
      return updated_at.strftime("%A")
    else:
      return updated_at.strftime("%d/%m/%Y")

  def render_datetime_tooltip():
    """ Returns a tooltip string for the message, showing the full date and time. """
    if updated_at is None: return ""
    return updated_at.strftime("%d/%m/%Y %H:%M")

  if description:
    second_row = [
      ft.Text(description, size=14, weight=ft.FontWeight.W_100, max_lines=1, overflow=ft.TextOverflow.ELLIPSIS, tooltip=description)
    ]
  else:
    second_row = []
  
  return ft.Container(
    content=ft.TextButton(
      on_click=handle_click,
      style=ft.ButtonStyle(
        shape=ft.RoundedRectangleBorder(radius=3),
        bgcolor=ft.Colors.SECONDARY_CONTAINER if selected else ft.Colors.TRANSPARENT,
      ),
      content=ft.Container(
        ft.Column(
          [
            ft.Row(
              [
                ft.Text(name, size=14, weight=ft.FontWeight.W_500, overflow=ft.TextOverflow.ELLIPSIS, tooltip=name, expand=True),
                ft.Text(render_time(), size=12, weight=ft.FontWeight.W_100, text_align=ft.TextAlign.RIGHT, tooltip=render_datetime_tooltip())
              ],
              spacing=10
            ),
            *second_row
          ],
          spacing=5
        ),
        padding=ft.padding.all(10)
      ),
      badge=badge
    ),
    padding=ft.padding.only(15, 0, 13, 0)
  )

@ft.component
def PopupMenuButton(tooltip, menu_items, icon=None, src=None) -> ft.Control:
  """ A wrapper around PopupMenuButton to simplify usage.
      Shape paramter has no effect, so a square shape has to be forced
      Two different configs can be returned for built in or custom icons
  """
  if icon:
    return ft.Container(
        content=ft.Stack(
          [
            ft.PopupMenuButton(
              icon=icon,
              tooltip=tooltip,
              items=menu_items,
              shape=ft.RoundedRectangleBorder(radius=3), # Has no effect
              width=80,
              height=80,
              left=-20,
              top=-20,
              splash_radius=35,
            ),
          ],
          clip_behavior=ft.ClipBehavior.HARD_EDGE,
          width=40,
          height=40
        ),
        padding=ft.padding.only(0,0,0,0),
        border_radius=ft.BorderRadius(3,3,3,3),
      )
  else:
    return ft.Container(
      content=ft.Stack(
        [
          ft.Image(
            src=src,
            width=30, height=30,
            top=5, left=5,
            color=ft.Colors.PRIMARY
          ),
          ft.PopupMenuButton(
            icon=icon,
            tooltip=tooltip,
            items=menu_items,
            shape=ft.RoundedRectangleBorder(radius=3), # Has no effect
            width=80,
            height=80,
            left=-20,
            top=-20,
            splash_radius=35,
            icon_size=0, # If not set to 0 may cause alignment issues
          ),
        ], clip_behavior=ft.ClipBehavior.HARD_EDGE,
        width=40,
        height=40
      ),
      padding=ft.padding.only(0,0,0,0),
      border_radius=ft.BorderRadius(3,3,3,3),
    )

@ft.component
def TextButton(on_click, text, tooltip=None, icon=None, visible=True, disabled=False, badge=None) -> ft.Control:
  """ Style lanugage for Text Area type button """
  return ft.TextButton(
    content=ft.Text(
      text,
      size=14,
      weight=ft.FontWeight.W_500
    ),
    tooltip=tooltip,
    on_click=on_click,
    style=ft.ButtonStyle(
      shape=ft.RoundedRectangleBorder(radius=3)
    ),
    margin=ft.margin.only(0, 0, 0, 0),
    height=40,
    icon=icon,
    visible=visible,
    disabled=disabled,
    badge=badge
  )

@ft.component
def WideTextButton(label, on_click) -> ft.Control:
  """ Full width TextButton formatted to the application's style language """
  return ft.Row(
    [
      ft.TextButton(
        height=40,
        expand=True,
        content=ft.Row(
          [
            ft.Icon(
              ft.Icons.CREATE_NEW_FOLDER_OUTLINED,
              size=16,
              color=ft.Colors.PRIMARY
            ),
            ft.Text(label),
          ],
          expand=True,
          spacing=6,
          alignment=ft.MainAxisAlignment.CENTER,
        ),
        on_click=on_click,
        style=ft.ButtonStyle(
          side=ft.BorderSide(
            1,
            ft.Colors.PRIMARY
          ),
          shape=ft.RoundedRectangleBorder(radius=3)
        )
      )
    ]
  )

def Badge() -> ft.Badge:
  """ Returns a standard badge for buttons """
  return ft.Badge(
    small_size=10,
    alignment=ft.Alignment.TOP_RIGHT
  )

# @ft.component
def Chip(icon, label, delete, on_delete) -> ft.Container:
  """ Creates a custom chip as the built in Chip behaves oddly """
  return ft.Container(
    content=ft.Row(
      [
        ft.Row(
          [
            # Leading icon
            ft.Icon(
              size=14,
              icon=icon,
              margin=ft.Margin.only(left=4)
            ),
            # Label
            ft.Text(
              size=14,
              value=label,
              expand=True,
              tooltip=label,
              overflow=ft.TextOverflow.ELLIPSIS
            )
          ],
          expand=True
        ),

        # Delete Button
        ft.IconButton(
          icon_size=14,
          on_click=on_delete,
          icon=ft.Icons.CLOSE_OUTLINED,
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3))
        )
      ],
      spacing=4,
      wrap=False
    ),
    height=40,
    border_radius=3,
    padding=ft.Padding.all(2),
    bgcolor=ft.Colors.SURFACE
  )
