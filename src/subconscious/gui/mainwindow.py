import flet as ft


class WorkspaceItem(ft.TextButton):
  def __init__(self, chat, toggle_func):
    super().__init__()
    self.chat = chat
    self.style = ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=5))
    self.last_updated = chat.updated_at.astimezone()
    self.on_click = self.highlight
    self.toggle_func = toggle_func

    self.content = ft.Container(ft.Column([
      ft.Row([
        ft.Text(self.chat.name, size=14, weight=ft.FontWeight.W_500, overflow=ft.TextOverflow.ELLIPSIS, tooltip=self.chat.name, expand=True),
        ft.Text(self.render_time(), size=12, weight=ft.FontWeight.W_100, text_align=ft.TextAlign.RIGHT, tooltip=self.render_datetime_tooltip())
      ], spacing=10),
      ft.Text(self.chat.description, size=14, weight=ft.FontWeight.W_100, max_lines=1, overflow=ft.TextOverflow.ELLIPSIS,
        tooltip=self.chat.description),
    ], spacing=5), padding=ft.padding.all(10))
  
  async def highlight(self, e):
    await self.toggle_func(self, str(self.chat.uuid))
    self.style = ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=5), bgcolor=ft.Colors.SECONDARY_CONTAINER)
    self.page.update()
  
  def render_time(self):
    """ Returns a human readable time string, adjusted for how long ago the message was sent. """
    now = datetime.now().astimezone()

    # Get the time difference
    diff = now - self.last_updated

    # If the message was sent today, return the time
    if diff.days == 0:
      return self.last_updated.strftime("%H:%M")
    # If the message was sent yesterday, return "Yesterday"
    elif diff.days == 1:
      return "Yesterday"
    # If the message was sent this week, return the day of the week (e.g. "Monday")
    elif diff.days < 7:
      return self.last_updated.strftime("%A")
    # Otherwise, return the date
    else:
      return self.last_updated.strftime("%d/%m/%Y")
  
  def render_datetime_tooltip(self):
    """ Returns a tooltip string for the message, showing the full date and time. """
    return self.last_updated.strftime("%d/%m/%Y %H:%M")


@ft.component
def MainWindow(current_view: str = "default") -> ft.Control:
  """ The main window for the UI """
  
  # Default placeholder if no content is provided
  default_content = ft.Container(ft.Column([
    ft.Image(
      src="/logo.svg",
      width=150, height=150,
      color=ft.Colors.GREY,
    ),
    ft.Text("Subconscious", size=35, color=ft.Colors.GREY, text_align=ft.TextAlign.CENTER),
  ], spacing=0, alignment=ft.MainAxisAlignment.CENTER, horizontal_alignment=ft.CrossAxisAlignment.CENTER, expand=True))

  # Choose content based on navigation state
  content = default_content
  if current_view == "threads":
    # Threads view usually has the chat messages here
    content = ft.Container(
      content=ft.Text("Select a thread to start chatting", size=16, color=ft.Colors.GREY_500),
      alignment=ft.Alignment.CENTER,
      expand=True
    )
  elif current_view == "workspace":
    # Main window when workspace is selected shows instructions/summary
    content = ft.Container(
      content=ft.Text("Select a workspace to view threads", size=16, color=ft.Colors.GREY_500),
      alignment=ft.Alignment.CENTER,
      expand=True
    )
  else:
    content = default_content

  return ft.Container(
    content=content,
    padding=0,
    expand=True,
    bgcolor=ft.Colors.SURFACE,
  )
