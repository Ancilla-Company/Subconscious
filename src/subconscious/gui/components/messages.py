import re
import json
import flet as ft
from math import pi
from datetime import datetime, timezone


# MarkdownCode Theme
CODE_THEME = ft.MarkdownCustomCodeTheme(
  keyword=ft.TextStyle(color=ft.Colors.PURPLE, font_family="Roboto Mono"),
  comment=ft.TextStyle(color=ft.Colors.SECONDARY, font_family="Roboto Mono"),
  class_name=ft.TextStyle(color=ft.Colors.BLUE, font_family="Roboto Mono"),
  function=ft.TextStyle(color=ft.Colors.BLUE, font_family="Roboto Mono"),
  string=ft.TextStyle(color=ft.Colors.GREEN, font_family="Roboto Mono"),
  variable=ft.TextStyle(color=ft.Colors.PRIMARY, font_family="Roboto Mono"),
)


class ToolMessage:
  """ A class to represent a tool message in the chat.
      A tool message is a message generated from a tool response, and may contain structured data that needs to be rendered differently from plain text messages.
  """
  def __init__(self, content):
    self.content = content
    self.type = 'tool'


class AIMessage:
  """ A class to represent an AI message in the chat.
      An AI message is a message generated from an LLM response, and may contain streaming content that needs to be updated incrementally in the GUI.
  """
  def __init__(self, content, timestamp=None):
    self.content = content
    self.type = 'ai'
    self.timestamp = timestamp if timestamp else datetime.now(timezone.utc)


class HumanMessage:
  """ A class to represent a human message in the chat.
      A human message is a message generated from user input, and may contain plain text content.
  """
  def __init__(self, content, timestamp=None):
    self.content = content
    self.type = 'human'
    self.timestamp = timestamp if timestamp else datetime.now(timezone.utc)


class MessageBubble(ft.Row):
  """ A class to represent a message bubble in the chat.
      A message bubble is a single message displaying text
  """
  def __init__(self, message):
    super().__init__()
    self.expand = True
    self.message = message
    self.parts = self.split_markdown_sections(self.message.content)
    self.message_content = ft.Text(self.message.content, size=14, color=ft.Colors.PRIMARY)
    self.alignment = "center"
    self.wrap = True

    # For streaming tokens
    self.buffer = '' # A buffer to hold the incoming token stream from LLMs
    self.part = 'text' # Keeps track of the current section while receiving token stream
    
    # Generate the content of the message bubble
    self.content = []

    # If tool message just render expansion tile
    if isinstance(self.message, ToolMessage):
      # Parse data may come with excessive escaping
      data = json.loads(self.message.content)
      if data.get('data') and isinstance(data['data'], list) and len(data['data']) > 0 and (isinstance(data['data'][0], str) or isinstance(data['data'][0], dict)):
        data['data'] = json.loads(data['data'][0])
      
      self.content.append(
        ft.Container(
          ft.ExpansionPanelList(
            expanded_header_padding=ft.padding.only(0,-14,0,-14),
            expand_icon_color=ft.Colors.PRIMARY,
            elevation=0,
            divider_color=ft.Colors.SECONDARY_CONTAINER,
            spacing=0,
            controls=[
              ft.ExpansionPanel(
                header=ft.Container(
                  content=ft.Text("Tool Response", size=14, color=ft.Colors.PRIMARY),
                  padding=ft.padding.only(10,15,4,5),
                ),
                bgcolor=ft.Colors.SURFACE_CONTAINER_HIGHEST,
                can_tap_header=True,
                content=ft.Container(ft.Markdown(
                  value=f"```json\n {json.dumps(data, indent=2)} \n```",
                  extension_set=ft.MarkdownExtensionSet.GITHUB_WEB,
                  code_theme=CODE_THEME,
                  code_style_sheet=ft.MarkdownStyleSheet(code_text_style=ft.TextStyle(font_family="Roboto Mono"), blockquote_text_style=ft.TextStyle(font_family="Roboto Mono")),
                ), padding=ft.padding.only(0, 0, 0, 0))
              )
            ],
          ),
          border_radius=ft.BorderRadius(3,3,3,3),
          padding=ft.padding.only(0,-10,0,-7)
        )
      )
    else:
      for part in self.parts:
        if part.startswith(("```", "~~~")):
          self.content.append(ft.Container(content=ft.Column([
              # Get the code block language
              ft.Container(content=ft.Row([
                ft.Row([
                  ft.Text(self.extract_code_block_headers(part).capitalize(), color=ft.Colors.PRIMARY, selectable=True),
                ], spacing=0, alignment="start", expand=True),
                ft.TextButton(text="Copy", icon="copy", on_click=lambda e: self.copy_code_block(e), data=part, tooltip="Copy",
                style=ft.ButtonStyle(text_style=ft.TextStyle(font_family="Roboto Mono", size=12), shape=ft.RoundedRectangleBorder(radius=3)),
                ),
                ], spacing=0), padding=ft.padding.only(10, 2, 2, 2),
              ),

              # Render the code block
              ft.Container(content=
                ft.Markdown(
                  part,
                  extension_set=ft.MarkdownExtensionSet.GITHUB_WEB,
                  code_theme=CODE_THEME,
                  code_style_sheet=ft.MarkdownStyleSheet(code_text_style=ft.TextStyle(font_family="Roboto Mono"), blockquote_text_style=ft.TextStyle(font_family="Roboto Mono")),
                ),
                border_radius=ft.BorderRadius(0,0,5,5),
              )
            ],
            spacing=0),
            padding=ft.padding.only(0, 0, 0, 0),
            bgcolor=ft.Colors.SURFACE,
            margin=ft.margin.only(bottom=10, top=10),
            border_radius=ft.BorderRadius(5,5,5,5),
            border=ft.border.all(1, ft.Colors.SECONDARY),  # Add a
          ))
        else:
          self.content.append(ft.Container(content=
              ft.Markdown(
                part,
              ),
              clip_behavior=ft.ClipBehavior.NONE,
            ))
    
    self.bubble_content = ft.Column([
      *self.content,

      # Message Bubble - timestamp and copy button
      *[ft.Container(content=ft.Row([
        ft.Container(content=
          ft.Stack([
            ft.IconButton(icon="copy", on_click=lambda e: self.copy_message(e), tooltip="Copy", style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)), icon_size=16, height=30, width=30, padding=4, top=-3, left=-3),
          ], width=25, height=25),
          border_radius=ft.border_radius.all(3),
        ),
      ft.Text(self.format_timestamp(self.message.timestamp) if hasattr(self.message, 'timestamp') else "--:--", size=12),
      ],spacing=5, height=25,
      wrap=True,
      alignment= "end" if message.type == 'human' else "start"
      ), padding=ft.padding.only(0, 10, 0, 0))]

    ], spacing=0, wrap=False)  # content
    
    self.controls = [
      ft.Row([
        ft.Container(
          ft.Stack([
            # Message pointer
            self.sender_message_pointer() if self.message.type == 'human' else self.receiver_message_pointer(),

            # Message bubble
            ft.Container(
              bgcolor=ft.Colors.PRIMARY_CONTAINER if self.message.type == 'human' else ft.Colors.SURFACE_CONTAINER_HIGHEST,
              border_radius = ft.BorderRadius(5, 5, 5, 5),
              padding = ft.padding.only(10, 5, 10, 5),
              content = self.bubble_content,

              margin=ft.margin.only(right=7, left=7),
            )

          ], clip_behavior=ft.ClipBehavior.NONE), clip_behavior=ft.ClipBehavior.NONE, 
          # width=750,
          # alignment= "end" if self.message.type == 'human' else "start",
        ),
      ], width=750, alignment= "end" if message.type == 'human' else "start", wrap=True),
    ]

  def update_message_stream(self, chunk, drain: bool = False):
    """ TODO:
        Implement incremental response updates similar to other LLM UIs
        Track which section the response is currently sending e.g. plain text, image, code etc
        Create a buffer to consume at least a line of response, before updating the GUI
        The buffer should break at line breaks or spaces or markdown formatting characters
        Any other UI features like fading in of the latest words/tokens is unncessary at this time
        Args:
        chunck: AI/Tool Message object
        drain: If True, drains the buffer as the message streaming is now complete
    """
    # Storing message content
    if not drain:
      self.message.content += chunk.content

    # Adding streaming tokens to the buffer
    if not drain:
      self.buffer += chunk.content

    # Patterns
    start_pattern = r"(```[^\n]*\n|~~~[^\n]*\n)"
    end_pattern = r"(```|~~~)"

    # Buffer is full at 99 characters
    if len(self.buffer) > 29 or drain:
      # Reset buffer split on last space to avoid cutting markdown delimeters
      if drain:
        temp = self.buffer
      else:
        temp, self.buffer = self.buffer[:self.buffer.rfind(' ')], self.buffer[self.buffer.rfind(' '):]

      while True:
        if self.part == 'text':
          # In a text part, search for code block start
          if search := re.search(start_pattern, temp):
            if self.bubble_content.controls[-2].content.page: self.bubble_content.controls[-2].content.update()

            # Append remaining part to the previous section
            self.bubble_content.controls[-2].content.value = self.bubble_content.controls[-2].content.value + temp[:search.start()]
            
            # start new code section
            self.part = 'code'

            # Check for the end of the part within the same temp buffer
            if end := re.search(end_pattern, temp[search.end():]):
              self.new_stream_code_block(temp[search.start():search.end() + end.end()])
              temp = temp[search.end() + end.end():]
              self.part = 'text'
              self.new_stream_text_block("")
            else:
              self.new_stream_code_block(temp[search.start():])
              break
          else:
            self.bubble_content.controls[-2].content.value = self.bubble_content.controls[-2].content.value + temp
            break

        elif self.part =='code':
          # In a code part, search for code block end
          if search := re.search(end_pattern, temp):
            # if hasattr(self.content[-1].content.controls[1].content, 'page'):
            if self.bubble_content.controls[-2].content.controls[1].content.page: self.bubble_content.controls[-2].content.controls[1].content.update()

            # Append remaining code to previous code block
            self.bubble_content.controls[-2].content.controls[1].content.value = self.bubble_content.controls[-2].content.controls[1].content.value + temp[:search.end()]

            # Start new text section
            self.part = 'text'

            # Check for start of new code section in buffer
            if start := re.search(start_pattern, temp[search.end():]):
              # self.content.append(ft.Markdown(temp[search.end():start.start()]))
              self.new_stream_text_block(temp[search.end():search.end() + start.start()])
              temp = temp[search.end() + start.start():]
              self.part = 'code'
              self.new_stream_code_block("")
            else:
              self.new_stream_text_block(temp[search.end():])
              break
          else:
            self.bubble_content.controls[-2].content.controls[1].content.value = self.bubble_content.controls[-2].content.controls[1].content.value + temp
            break
    
    # If draining, update the bubble timestamp
    if drain:
      self.bubble_content.controls[-1].content.controls[1].value = chunk.timestamp.strftime("%H:%M")

    self.page.update()
  
  def new_stream_text_block(self, part):
    """ Appends a new text section to the message bubble """
    self.bubble_content.controls.insert(-1, ft.Container(content=
      ft.Markdown(
        part,
      ),
      clip_behavior=ft.ClipBehavior.NONE,
    ))
    self.page.update()
  
  def new_stream_code_block(self, part):
    """ Append a new code or special markdown block to the content """
    self.bubble_content.controls.insert(-1, ft.Container(content=ft.Column([
        # Get the code block language
        ft.Container(content=ft.Row([
          ft.Row([
            ft.Text(self.extract_code_block_headers(part).capitalize(), color=ft.Colors.PRIMARY, selectable=True),
          ], spacing=0, alignment="start", expand=True),
          ft.TextButton(text="Copy", icon="copy", on_click=lambda e: self.copy_code_block(e), data=part, tooltip="Copy",
          style=ft.ButtonStyle(text_style=ft.TextStyle(font_family="Roboto Mono", size=12), shape=ft.RoundedRectangleBorder(radius=3)),
          ),
          ], spacing=0), padding=ft.padding.only(10, 2, 2, 2),
        ),

        # Render the code block
        ft.Container(content=
          ft.Markdown(
            part,
            extension_set=ft.MarkdownExtensionSet.GITHUB_WEB,
            code_theme=CODE_THEME,
            code_style_sheet=ft.MarkdownStyleSheet(code_text_style=ft.TextStyle(font_family="Roboto Mono"), blockquote_text_style=ft.TextStyle(font_family="Roboto Mono")),
          ),
          border_radius=ft.BorderRadius(0,0,5,5),
        )
      ],
      spacing=0),
      padding=ft.padding.only(0, 0, 0, 0),
      bgcolor=ft.Colors.SURFACE,
      margin=ft.margin.only(bottom=10, top=10),
      border_radius=ft.BorderRadius(5,5,5,5),
      border=ft.border.all(1, ft.Colors.SECONDARY),  # Add a
    ))
    self.page.update()

  def split_markdown_sections(self, md_text):
    # Regex pattern to capture triple-delimited blocks (``` or ~~~) along with their content
    pattern = r"(```.*?```|~~~.*?~~~)"  # Captures code blocks including delimiters
    
    # Split the markdown by these sections while keeping them in the result
    parts = re.split(pattern, md_text, flags=re.DOTALL)
    
    return parts
  
  def extract_code_block_headers(self, md_text):
    # Regex pattern to match code blocks with optional language identifiers
    pattern = r"(```[^\n]*\n|~~~[^\n]*\n)"  # Captures the opening line of code blocks
    
    # Find all matching headers
    headers = re.findall(pattern, md_text)
    
    # Clean up headers by removing the triple delimiters and extra spaces
    headers = [header.strip().strip('`~') for header in headers]
    
    return headers[0] if headers else "Code"
  
  def copy_code_block(self, e):
    """ Copy code block to clipboard and strip the code block delimiters and headers """
    e.page.set_clipboard(e.control.data.strip('`~').split('\n', 1)[1].strip())
  
  def copy_message(self, e):
    """ Copy the message content to clipboard """
    e.page.set_clipboard(self.message.content)
  
  
  def receiver_message_pointer(self):
    return ft.Container(
      border_radius=ft.BorderRadius(2, 2, 2, 2),
      width=20,
      height=15,
      left=0,
      alignment=ft.alignment.top_left,
      content = ft.Stack([
        ft.Container(
          bgcolor=ft.Colors.SURFACE_CONTAINER_HIGHEST,
          width=20,
          height=15,
          border_radius=ft.BorderRadius(2, 2, 2, 2),
          rotate=pi/2,
          offset=ft.Offset(0.525, -0.1)
        ),
        ft.Container(
          bgcolor=ft.Colors.SURFACE_CONTAINER_HIGHEST,
          width=20,
          height=15,
          border_radius=ft.BorderRadius(2, 2, 2, 2),
          rotate=pi/4,
          offset=ft.Offset(0.075, -0.3),
        ),
      ])
    )

  def sender_message_pointer(self):
    return ft.Container(
      border_radius=ft.BorderRadius(2, 2, 2, 2),
      width=20,
      height=15,
      right=0,
      alignment=ft.alignment.top_right,
      content = ft.Stack([
        ft.Container(
          bgcolor=ft.Colors.PRIMARY_CONTAINER,
          width=20,
          height=15,
          border_radius=ft.BorderRadius(2, 2, 2, 2),
          rotate=pi/2,
          offset=ft.Offset(-0.525, -0.1)
        ),
        ft.Container(
          bgcolor=ft.Colors.PRIMARY_CONTAINER,
          width=20,
          height=15,
          border_radius=ft.BorderRadius(2, 2, 2, 2),
          rotate=3*(pi/4),
          offset=ft.Offset(-0.075, -0.3),
        ),
      ])
    )
  
  def format_timestamp(self, timestamp):
    now = datetime.now(timezone.utc)
    if not isinstance(timestamp, datetime):
      return "--:--"
    delta = now - timestamp
    if delta.days == 0:
      # Today: show time with am/pm
      return timestamp.strftime("%I:%M %p").lstrip("0")
    elif delta.days < 7:
      # Within a week: show abbreviated day and date
      return timestamp.strftime("%I:%M %p %a").lstrip("0")
    elif delta.days < 30:
      # Within a month: show month, day, and time
      return timestamp.strftime("%I:%M %p %a %d %b").lstrip("0")
    else:
      # Over a year ago: show year, month, day
      return timestamp.strftime("%I:%M %p %a %d %b %Y")
  
  def get_initials(self, user_name: str):
    return user_name[:1].capitalize()

  def get_avatar_color(self, user_name: str):
    Colors_lookup = [
      ft.Colors.AMBER,
      ft.Colors.BLUE,
      ft.Colors.BROWN,
      ft.Colors.CYAN,
      ft.Colors.GREEN,
      ft.Colors.INDIGO,
      ft.Colors.LIME,
      ft.Colors.ORANGE,
      ft.Colors.PINK,
      ft.Colors.PURPLE,
      ft.Colors.RED,
      ft.Colors.TEAL,
      ft.Colors.YELLOW,
    ]

    return Colors_lookup[hash(user_name) % len(Colors_lookup)]
