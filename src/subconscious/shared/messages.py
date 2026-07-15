import re
import json
import flet as ft
from math import pi
import flet_lottie as ftl
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
  def __init__(self, content, timestamp=None):
    self.content = content
    self.type = 'tool'
    self.timestamp = timestamp if timestamp else datetime.now(timezone.utc)


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


class ApprovalMessage:
  """ A human-in-the-loop approval prompt for a gated tool call.

      Rendered with Approve / Deny buttons that resolve the pending approval on
      the engine. ``resolved`` is None while awaiting a decision, then True
      (approved) or False (denied). These messages are transient to a live turn
      and are not persisted.
  """
  def __init__(self, tool_name, args, tool_call_id, operation="mutation",
               engine=None, resolved=None, timestamp=None):
    self.tool_name = tool_name
    self.args = args
    self.tool_call_id = tool_call_id
    self.operation = operation
    self.engine = engine
    self.resolved = resolved
    self.type = 'approval'
    # Non-empty so the bubble renders its content rather than the waiting dots.
    self.content = f"approval:{tool_call_id}"
    self.timestamp = timestamp if timestamp else datetime.now(timezone.utc)


class MessageBubble(ft.Row):
  """ A class to represent a message bubble in the chat.
      A message bubble is a single message displaying text
  """
  def __init__(self, message, show_pointer: bool = True):
    super().__init__()
    self.wrap = True
    self.expand = True
    self.message = message
    # Only the first bubble in a run of same-side messages shows the little
    # tail/pointer; successive bubbles in the block omit it for a cleaner group.
    self.show_pointer = show_pointer
    self.alignment = ft.MainAxisAlignment.CENTER
    self.parts = self.split_markdown_sections(self.message.content)
    self.message_content = ft.Text(self.message.content, size=14, color=ft.Colors.PRIMARY)

    # Animated waiting ellipses (Lottie animation, to be fixed)
    # self.elipses = self.waiting_animation()
    self.elipses = ft.Text(
      ". . . ",
      size=13,
      weight=ft.FontWeight.BOLD
    )

    # For streaming tokens
    self.buffer = '' # A buffer to hold the incoming token stream from LLMs
    self.part = 'text' # Keeps track of the current section while receiving token stream
    
    # Generate the content of the message bubble
    self.content = []

    # If tool message, render an expandable panel showing input + output.
    if isinstance(self.message, ToolMessage):
      tool_name, input_data, output_data, outcome = self._parse_tool_message(self.message.content)
      header_label = f"Tool: {tool_name}" if tool_name else "Tool Call"
      if outcome and outcome != "success":
        header_label += f"  ({outcome})"

      def _json_md(value):
        try:
          rendered = json.dumps(value, indent=2, default=str)
        except (TypeError, ValueError):
          rendered = str(value)
        return ft.Markdown(
          value=f"```json\n{rendered}\n```",
          extension_set=ft.MarkdownExtensionSet.GITHUB_WEB,
          code_theme=CODE_THEME,
          code_style_sheet=ft.MarkdownStyleSheet(
            code_text_style=ft.TextStyle(font_family="Roboto Mono"),
            blockquote_text_style=ft.TextStyle(font_family="Roboto Mono")
          ),
        )

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
                  content=ft.Row(
                    [
                      ft.Icon(ft.Icons.BUILD, size=15, color=ft.Colors.PRIMARY),
                      ft.Text(header_label, size=14, color=ft.Colors.PRIMARY),
                    ],
                    spacing=6,
                  ),
                  padding=ft.padding.only(10,15,4,5),
                ),
                bgcolor=ft.Colors.SURFACE_CONTAINER_HIGHEST,
                can_tap_header=True,
                content=ft.Container(
                  ft.Column(
                    [
                      ft.Text("Input", size=12, color=ft.Colors.SECONDARY),
                      _json_md(input_data),
                      ft.Text("Output", size=12, color=ft.Colors.SECONDARY),
                      _json_md(output_data),
                    ],
                    spacing=2,
                  ),
                  padding=ft.padding.only(10, 0, 10, 8)
                )
              )
            ]
          ),
          border_radius=ft.BorderRadius(3,3,3,3),
          padding=ft.padding.only(0,-10,0,-7)
        )
      )

    # Approval prompt: input + Approve/Deny controls (or the decision made).
    elif isinstance(self.message, ApprovalMessage):
      self.content.append(self._build_approval_panel())
    else:
      for part in self.parts:
        if part.startswith(("```", "~~~")):
          self.content.append(
            ft.Container(
              content=ft.Column(
                [
                  # Get the code block language
                  ft.Container(
                    content=ft.Row(
                      [
                        ft.Row(
                          [
                            ft.Text(
                              self.extract_code_block_headers(part).capitalize(),
                              color=ft.Colors.PRIMARY,
                              selectable=True
                            )
                          ],
                          spacing=0,
                          alignment="start",
                          expand=True
                        ),
                        ft.IconButton(
                          icon=ft.Icons.COPY,
                          icon_size=16,
                          height=30,
                          width=30,
                          padding=4,
                          on_click=self.copy_code_block,
                          data=part,
                          tooltip="Copy",
                          style=ft.ButtonStyle(
                            text_style=ft.TextStyle(font_family="Roboto Mono", size=12),
                            shape=ft.RoundedRectangleBorder(radius=3)
                          ),
                        ),
                      ], 
                      spacing=0
                    ),
                    padding=ft.padding.only(10, 2, 2, 2)
                  ),

                  # Render the code block
                  ft.Container(
                    content=ft.Markdown(
                      part,
                      extension_set=ft.MarkdownExtensionSet.GITHUB_WEB,
                      code_theme=CODE_THEME,
                      code_style_sheet=ft.MarkdownStyleSheet(
                        code_text_style=ft.TextStyle(font_family="Roboto Mono"),
                        blockquote_text_style=ft.TextStyle(font_family="Roboto Mono")
                      ),
                    ),
                    border_radius=ft.BorderRadius(0, 0, 3, 3),
                  )
                ],
                spacing=0
              ),
              padding=ft.padding.only(0, 0, 0, 0),
              bgcolor=ft.Colors.SURFACE,
              margin=ft.margin.only(bottom=10, top=10),
              border_radius=ft.BorderRadius(3, 3, 3, 3),
              border=ft.border.all(1, ft.Colors.SECONDARY),
            )
          )
        else:
          self.content.append(
            ft.Container(
              content=ft.Markdown(part),
              clip_behavior=ft.ClipBehavior.NONE,
            )
          )
    
    self.bubble_content = ft.Column(
      [
        *(self.content if self.message.content else [self.elipses]),

        # Message Bubble - timestamp and copy button
        *[
          ft.Container(
            content=ft.Row(
              [
                ft.IconButton(
                  icon=ft.Icons.COPY,
                  on_click=self.copy_message,
                  tooltip="Copy",
                  style=ft.ButtonStyle(
                    shape=ft.RoundedRectangleBorder(radius=3)
                  ),
                  icon_size=16,
                  height=30,
                  width=30,
                  padding=4,
                ),
                ft.Text(
                  self.format_timestamp(self.message.timestamp) if hasattr(self.message, 'timestamp') else "--:--",
                  size=12,
                  height=20
                ),
              ],
              spacing=5,
              height=25,
              wrap=True,
              alignment= "end" if message.type == 'human' else "start"
            ),
            padding=ft.padding.only(0, 5, 0, 5)
          )
        ]
      ],
      spacing=0,
      wrap=False
    )
    
    # Message bubble body
    bubble = ft.Container(
      bgcolor=ft.Colors.PRIMARY_CONTAINER if self.message.type == 'human' else ft.Colors.SURFACE_CONTAINER_HIGHEST,
      border_radius = ft.BorderRadius(3, 3, 3, 3),
      padding = ft.padding.only(10, 5, 10, 5),
      content = self.bubble_content,
      margin=ft.margin.only(right=7, left=7),
    )

    # Stack the pointer behind the bubble only for the first message in a block.
    stack_controls = []
    if self.show_pointer:
      stack_controls.append(
        self.sender_message_pointer() if self.message.type == 'human' else self.receiver_message_pointer()
      )
    stack_controls.append(bubble)

    self.controls = [
      ft.Row(
        [
          ft.Container(
            ft.Stack(
              stack_controls,
              clip_behavior=ft.ClipBehavior.NONE),
              clip_behavior=ft.ClipBehavior.NONE, 
              padding=ft.padding.only(13, 0, 15, 0)
          ),
        ],
        width=750,
        alignment=ft.MainAxisAlignment.END if message.type == 'human' else ft.MainAxisAlignment.START,
        wrap=True
      )
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
        last_space = self.buffer.rfind(' ')
        if last_space != -1:
          temp, self.buffer = self.buffer[:last_space], self.buffer[last_space:]
        else:
          # If no space, just take the whole buffer and clear it
          temp, self.buffer = self.buffer, ""

      while True:
        if not temp:
          break
          
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
          ft.TextButton(text="Copy", icon="copy", on_click=self.copy_code_block, data=part, tooltip="Copy",
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

  def _build_approval_panel(self):
    """Build the approval prompt UI (input + Approve/Deny or the decision)."""
    msg = self.message
    try:
      args_json = json.dumps(msg.args, indent=2, default=str)
    except (TypeError, ValueError):
      args_json = str(msg.args)

    op_label = "modifies data" if msg.operation == "mutation" else "reads data"
    header = ft.Row(
      [
        ft.Icon(ft.Icons.SHIELD, size=16, color=ft.Colors.PRIMARY),
        ft.Text(f"Approval required — {msg.tool_name}", size=14,
                color=ft.Colors.PRIMARY, expand=True),
        ft.Text(op_label, size=11, color=ft.Colors.SECONDARY),
      ],
      spacing=6,
    )

    input_md = ft.Markdown(
      value=f"```json\n{args_json}\n```",
      extension_set=ft.MarkdownExtensionSet.GITHUB_WEB,
      code_theme=CODE_THEME,
      code_style_sheet=ft.MarkdownStyleSheet(
        code_text_style=ft.TextStyle(font_family="Roboto Mono"),
        blockquote_text_style=ft.TextStyle(font_family="Roboto Mono")
      ),
    )

    self._approve_btn = ft.ElevatedButton(
      "Approve", icon=ft.Icons.CHECK,
      on_click=lambda e: self._resolve_approval(True),
      style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
    )
    self._deny_btn = ft.OutlinedButton(
      "Deny", icon=ft.Icons.CLOSE,
      on_click=lambda e: self._resolve_approval(False),
      style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
    )
    self._decision_row = ft.Row([self._approve_btn, self._deny_btn], spacing=8)
    self._apply_decision_state()

    return ft.Container(
      ft.Column([header, input_md, self._decision_row], spacing=6),
      bgcolor=ft.Colors.SURFACE_CONTAINER_HIGHEST,
      border=ft.border.all(1, ft.Colors.PRIMARY),
      border_radius=ft.BorderRadius(3, 3, 3, 3),
      padding=ft.padding.only(10, 8, 10, 8),
    )

  def _apply_decision_state(self):
    """Show Approve/Deny while pending, or a status label once resolved."""
    resolved = getattr(self.message, "resolved", None)
    if resolved is None:
      self._approve_btn.disabled = False
      self._deny_btn.disabled = False
      return
    label = "✓ Approved" if resolved else "✕ Denied"
    color = ft.Colors.GREEN if resolved else ft.Colors.ERROR
    self._decision_row.controls = [ft.Text(label, size=13, color=color)]

  def _resolve_approval(self, approved: bool):
    """Handle an Approve/Deny click: resolve on the engine and update UI."""
    msg = self.message
    if getattr(msg, "resolved", None) is not None:
      return
    msg.resolved = approved
    engine = getattr(msg, "engine", None)
    if engine is not None:
      try:
        engine.resolve_approval(msg.tool_call_id, approved)
      except Exception:
        pass
    self._apply_decision_state()
    try:
      self.update()
    except Exception:
      pass

  def _parse_tool_message(self, raw):
    """Parse a ToolMessage's JSON content into (tool_name, input, output, outcome).

    Tolerates malformed or legacy content: anything that isn't the expected
    JSON object falls back to showing the raw value as the output.
    """
    try:
      data = json.loads(raw)
    except (TypeError, ValueError):
      return "", None, raw, "success"
    if not isinstance(data, dict):
      return "", None, data, "success"
    return (
      data.get("tool_name", ""),
      data.get("input"),
      data.get("output"),
      data.get("outcome", "success"),
    )

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
  
  async def copy_code_block(self, e):
    """ Copy code block to clipboard and strip the code block delimiters and headers """
    await ft.Clipboard().set(e.control.data.strip('`~').split('\n', 1)[1].strip())
  
  async def copy_message(self, e):
    """ Copy the message content to clipboard """
    await ft.Clipboard().set(self.message.content)
  
  def receiver_message_pointer(self):
    return ft.Container(
      border_radius=ft.BorderRadius(2, 2, 2, 2),
      width=20,
      height=15,
      left=0,
      alignment=ft.Alignment.TOP_LEFT,
      content = ft.Stack(
        [
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
        ]
      )
    )

  def sender_message_pointer(self):
    return ft.Container(
      border_radius=ft.BorderRadius(2, 2, 2, 2),
      width=20,
      height=15,
      right=0,
      alignment=ft.Alignment.TOP_RIGHT,
      content = ft.Stack(
        [
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
        ]
      )
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
  
  def waiting_animation(self):
    """ Lottie bouncing-dots animation to indicate waiting on a response """
    animation = {
      "v": "4.8.0",
      "fr": 24,
      "ip": 0,
      "op": 60,
      "w": 80,
      "h": 30,
      "ddd": 0,
      "assets": [],
      "layers": [
        {
          "ddd": 0, "ty": 4, "sr": 1, 
          "ks": {
            "o": {"a": 0, "k": 100}, "r": {"a": 0, "k": 0}, 
            "p": {
              "a": 1, "k": [
                {"i": {"x": 0.42, "y": 1}, "o": {"x": 0.58, "y": 0}, "t": 20, "s": [65, 22]},
                {"i": {"x": 0.42, "y": 1}, "o": {"x": 0.58, "y": 0}, "t": 30, "s": [65, 8]},
                {"i": {"x": 0.42, "y": 1}, "o": {"x": 0.58, "y": 0}, "t": 40, "s": [65, 22]},
                {"t": 60, "s": [65, 22]}
              ]
            }, 
            "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]}
          },
              "shapes": [{
                  "ty": "gr", "it": [
                      {
                          "ty": "sh", 
                          "ks": {
                              "a": 0, 
                              "k": {
                                  "i": [[0, -1.6], [1.6, 0], [0, 1.6], [-1.6, 0]], 
                                  "o": [[0, 1.6], [-1.6, 0], [0, -1.6], [1.6, 0]], 
                                  "v": [[3, 0], [0, 3], [-3, 0], [0, -3]], 
                                  "c": True
                              }
                          }
                      },
                      {"ty": "fl", "c": {"a": 0, "k": [0.55, 0.55, 0.55, 1]}, "o": {"a": 0, "k": 100}},
                      {"ty": "tr", "p": {"a": 0, "k": [0, 0]}, "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]}, "r": {"a": 0, "k": 0}, "o": {"a": 0, "k": 100}}
                  ]
              }],
              "ip": 0, "op": 60, "st": 0
          },
          {
              "ddd": 0, "ty": 4, "sr": 1, 
              "ks": {
                  "o": {"a": 0, "k": 100}, "r": {"a": 0, "k": 0}, 
                  "p": {
                      "a": 1, "k": [
                          {"i": {"x": 0.42, "y": 1}, "o": {"x": 0.58, "y": 0}, "t": 10, "s": [40, 22]},
                          {"i": {"x": 0.42, "y": 1}, "o": {"x": 0.58, "y": 0}, "t": 20, "s": [40, 8]},
                          {"i": {"x": 0.42, "y": 1}, "o": {"x": 0.58, "y": 0}, "t": 30, "s": [40, 22]},
                          {"t": 60, "s": [40, 22]}
                      ]
                  }, 
                  "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]}
              },
              "shapes": [{
                  "ty": "gr", "it": [
                      {
                          "ty": "sh", 
                          "ks": {
                              "a": 0, 
                              "k": {
                                  "i": [[0, -1.6], [1.6, 0], [0, 1.6], [-1.6, 0]], 
                                  "o": [[0, 1.6], [-1.6, 0], [0, -1.6], [1.6, 0]], 
                                  "v": [[3, 0], [0, 3], [-3, 0], [0, -3]], 
                                  "c": True
                              }
                          }
                      },
                      {"ty": "fl", "c": {"a": 0, "k": [0.55, 0.55, 0.55, 1]}, "o": {"a": 0, "k": 100}},
                      {"ty": "tr", "p": {"a": 0, "k": [0, 0]}, "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]}, "r": {"a": 0, "k": 0}, "o": {"a": 0, "k": 100}}
                  ]
              }],
              "ip": 0, "op": 60, "st": 0
          },
          {
              "ddd": 0, "ty": 4, "sr": 1, 
              "ks": {
                  "o": {"a": 0, "k": 100}, "r": {"a": 0, "k": 0}, 
                  "p": {
                      "a": 1, "k": [
                          {"i": {"x": 0.42, "y": 1}, "o": {"x": 0.58, "y": 0}, "t": 0, "s": [15, 22]},
                          {"i": {"x": 0.42, "y": 1}, "o": {"x": 0.58, "y": 0}, "t": 10, "s": [15, 8]},
                          {"i": {"x": 0.42, "y": 1}, "o": {"x": 0.58, "y": 0}, "t": 20, "s": [15, 22]},
                          {"t": 60, "s": [15, 22]}
                      ]
                  }, 
                  "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]}
              },
              "shapes": [{
                  "ty": "gr", "it": [
                      {
                          "ty": "sh", 
                          "ks": {
                              "a": 0, 
                              "k": {
                                  "i": [[0, -1.6], [1.6, 0], [0, 1.6], [-1.6, 0]], 
                                  "o": [[0, 1.6], [-1.6, 0], [0, -1.6], [1.6, 0]], 
                                  "v": [[3, 0], [0, 3], [-3, 0], [0, -3]], 
                                  "c": True
                              }
                          }
                      },
                      {"ty": "fl", "c": {"a": 0, "k": [0.55, 0.55, 0.55, 1]}, "o": {"a": 0, "k": 100}},
                      {"ty": "tr", "p": {"a": 0, "k": [0, 0]}, "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]}, "r": {"a": 0, "k": 0}, "o": {"a": 0, "k": 100}}
                  ]
              }],
              "ip": 0, "op": 60, "st": 0
          }
      ]
    }

    return ft.SafeArea(
      ft.Container(
        ftl.Lottie(
          width=80,
          height=30,
          repeat=True,
          animate=True,
          enable_merge_paths=True,
          enable_layers_opacity=True,
          src=json.dumps(animation).encode("utf-8"),
          error_content=ft.Placeholder(ft.Text(". . .")),
          on_error=lambda e: print(f"Error loading Lottie: {e.data}")
        )
      )
    )
