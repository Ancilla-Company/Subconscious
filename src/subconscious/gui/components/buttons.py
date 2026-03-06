import flet as ft
from datetime import datetime


def SidebarButton(icon, tooltip, view_name, selected_view, callback, key=None, active=True):
  is_selected = (selected_view == view_name) if active else False
    
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
    ),
    clip_behavior=ft.ClipBehavior.HARD_EDGE,
  )

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

@ft.component
def IconButton(on_click, icon, tooltip=None) -> ft.Control:
  """ A button component that displays a built in icon. """
  return ft.IconButton(
    icon=icon,
    tooltip=tooltip,
    on_click=on_click,
    style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
  )

@ft.component
def ContextItem(name, description, updated_at, on_click):
  is_selected, set_is_selected = ft.use_state(False)

  def handle_click(e):
    set_is_selected(True)
    if on_click:
      on_click(e)
  
  def render_time():
    """ Returns a human readable time string, adjusted for how long ago the message was sent. """
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
    return updated_at.strftime("%d/%m/%Y %H:%M")

  return ft.TextButton(
    on_click=handle_click,
    style=ft.ButtonStyle(
      shape=ft.RoundedRectangleBorder(radius=3),
      bgcolor=ft.Colors.SECONDARY_CONTAINER if is_selected else ft.Colors.TRANSPARENT,
    ),
    content=ft.Container(
      ft.Column([
        ft.Row([
          ft.Text(name, size=14, weight=ft.FontWeight.W_500, overflow=ft.TextOverflow.ELLIPSIS, tooltip=name, expand=True),
          ft.Text(render_time(), size=12, weight=ft.FontWeight.W_100, text_align=ft.TextAlign.RIGHT, tooltip=render_datetime_tooltip())
        ], spacing=10),
          ft.Text(description, size=14, weight=ft.FontWeight.W_100, max_lines=1, overflow=ft.TextOverflow.ELLIPSIS, tooltip=description)
      ], spacing=5),
      padding=ft.padding.all(10)
    )
  )

ft.component
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
