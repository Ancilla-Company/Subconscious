import flet as ft
from math import ceil
import pathlib as _pl

from ...shared.buttons import IconButton, PopupMenuButton, Chip
from ...shared.messages import MessageBubble, HumanMessage, AIMessage


class ToolMenu(ft.Container):
  def __init__(self, settings, load_tools, thread_id=None):
    super().__init__()
    self.slugs = []
    self.visible=True
    self.settings = settings
    self.thread_id = thread_id
    self.load_tools = load_tools
    self.border_radius=ft.BorderRadius(3,3,3,3) # For some reason using 3 for all radii doesn't look right
    self.clip_behavior=ft.ClipBehavior.HARD_EDGE

    self.content=ft.Row(
      [
        ft.Container(
          content=ft.Stack([
              ft.Image(
                src="./tools.svg",
                width=25,
                height=25,
                top=7.5,
                left=7.5,
                color=ft.Colors.PRIMARY
              ),
              ft.PopupMenuButton(
                icon=None,
                shape=ft.RoundedRectangleBorder(radius=3), # Has no effect
                width=200,
                height=2000,
                left=-50,
                top=-50,
                splash_radius=35,
                icon_size=0,
                tooltip="Tools",
                items=[
                  # *self.load_tools_ui()
                ],
              ),
            ],
            clip_behavior=ft.ClipBehavior.HARD_EDGE,
            width=40,
            height=40
          ),
          padding=ft.padding.only(0,0,0,0),
        )
      ],
      height=40,
      width=40,
      spacing=0
    )

  def add_tool(self, slug):
    new_tool_item = ToolItem(self.settings, slug, self.thread_id)
    self.content.controls[0].content.controls[1].items.insert(0, new_tool_item)
    # self.update()
  
  def enable_tool(self, slug):
    """ Tools are disabled greyed out until loaded on the backend succeeds """
    for tool in self.content.controls[0].content.controls[1].items:
      if tool.data == slug:
        tool.disabled = False
        tool.content.content.controls[0].disabled = False
        tool.content.content.controls[0].label.content.controls[0].visible = False # Hide error icon
        break
    if self.page:
      self.page.update()

  def disable_tool(self, slug):
    """ Tools are disabled greyed out until loaded on the backend succeeds """
    for tool in self.content.controls[0].content.controls[1].items:
      if tool.data == slug:
        tool.disabled = True
        tool.content.content.controls[0].disabled = True
        tool.content.content.controls[0].label.content.controls[0].visible = True # Show error icon
        break
    if self.page:
      self.page.update()
  
  def tools_configured(self) -> bool:
    """ Determines if there are tools correctly configured and therefore if to show tool button
    """
    if len(self.settings['_tools']) > 0:
      for tool in self.settings['_tools'].values():
        if tool.get('url', "") != "":
          return True
    return False
  
  async def update_tools(self, slug: str, key: str) -> None:
    """ Update the tool menu items based on the current settings
        Should tool be visible or not, resfresh the tool given updated settings

        Args
        key: string, the change action taken
        slug: the specific tool slug
    """
    if key == 'delete':
      for item in self.content.controls[0].content.controls[1].items:
        if item.data == slug:
          # Remove tool from UI
          self.content.controls[0].content.controls[1].items.remove(item)
          self.slugs.remove(slug)

          # Trigger the tool removal callback 
          await ToolsQueue.put((slug, None, self.thread_id, "delete"))
          break
    else:
      if slug in self.slugs:
        for item in self.content.controls[0].content.controls[1].items:
          if item.data == slug:
            if key == 'name':
              # Update tool name
              item.name = self.settings['_tools'][slug]['name']
              item.content.content.controls[0].label.content.value = item.name

            elif key == 'url' and self.settings['_tools'][slug]['url'] == "":
              # Remove tool from popup
              self.content.controls[0].content.controls[1].items.remove(item)
              self.slugs.remove(slug)

              # Trigger tool delete callback
              await ToolsQueue.put((slug, None, self.thread_id, "delete"))
              
            else:
              # Trigger tool update callback
              await ToolsQueue.put((slug, None, self.thread_id, "update"))
            break
      else:
        # Add new tool to UI
        if self.settings['_tools'][slug].get('url', "") != "":
          self.add_tool(slug)
          self.slugs.append(slug)

    # Check if tools are configured if not hide button
    if not self.tools_configured():
      self.visible = False

  def load_tools_ui(self):
    """ Loads the configured tools on initiation """
    # Start with refresh button
    tools = [
      ft.TextButton(
        height=30,
        icon=ft.Icons.REFRESH,
        content="Refresh Tools",
        on_click=self.load_tools
      )
    ]

    # for slug, config in reversed(self.settings['_tools'].items()):
    #   if config.get('url', "") != "":
    #     tools.append(ToolItem(self.settings, slug, initialization=True))
    #     self.slugs.append(slug)
    # return tools
    return []

  def reload_load_tools(self, thread_id):
    """ Reload the toggle with the configured tools for the current thread """
    # Start with refresh button
    tools = [
      ft.TextButton("Refresh Tools", on_click=self.load_tools, icon=ft.Icons.REFRESH, height=30)
    ]
    self.slugs = []
    for slug, config in reversed(self.settings['_tools'].items()):
      if config.get('url', "") != "":
        tools.append(ToolItem(self.settings, slug, thread_id))
        self.slugs.append(slug)
    self.content.controls[0].content.controls[1].items = tools


@ft.component
def ChatWindow(
  thread=None,
  messages=None,
  streaming_text: str = "",
  on_list_mounted=None,
  on_send_message=None,
  is_streaming=False,
  model_configs=None,
  selected_model_config=None,
  on_model_select=None
) -> ft.Control:
  """ Handles the main chat window, including message display and input form """
  fp = ft.FilePicker() # Initialize and add file picker to page
  
  # Message state
  message_text, set_message_text = ft.use_state("")
  # Attatchment row height
  height, set_height = ft.use_state(40)

  # Attachments: list of dicts  {"path": str, "type": "file"|"folder", "name": str}
  attachments, set_attachments = ft.use_state([])

  # Dummy state and logic to resolve rendering errors from older version
  def llm_configured(): return True
  def focus_message_form(e): pass

  # ── Attachment helpers ───────────────────────────────────────────────────
  def remove_attachment(path: str):
    """ Remove attqchment helper """
    set_attachments([a for a in attachments if a["path"] != path])

  async def handle_pick_files(e):
    """ File picker helper """
    _attachments = []
    res = await fp.pick_files(allow_multiple=True, dialog_title="Select files")

    if res:
      for f in res:
        if f.path:
          if any(a["path"] == f.path for a in attachments): continue
          _attachments.append({"path": f.path, "type": "file", "name": _pl.Path(f.path).name or f.path})

    set_attachments(_attachments + attachments)

  async def handle_pick_folder(e):
    """ Folder picker helper """
    res = await fp.get_directory_path(dialog_title="Select folder")
    if res:
      if any(a["path"] == res.path for a in attachments): return
      set_attachments(attachments + [{"path": res, "type": "folder", "name": _pl.Path(res).name or res}])

  async def handle_submit(e):
    """ Handle submit """
    if message_text.strip() and not is_streaming:
      user_msg_content = message_text
      current_attachments = list(attachments)
      set_message_text("")
      set_attachments([])

      if on_send_message:
        await on_send_message(user_msg_content, current_attachments)

  chat_name = thread.title if thread else "New Thread"
  chatwindow_header = ft.Container(
    ft.Row(
      [
        ft.Text(chat_name, size=14, text_align=ft.TextAlign.LEFT, weight=ft.FontWeight.W_500, expand=True, color=ft.Colors.PRIMARY),
        # ft.IconButton(
        #   icon=ft.Icons.MORE_VERT_ROUNDED,
        #   tooltip="More",
        #   style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
        #   on_click=lambda e: print("Show chat settings"),
        # )
      ],
      height=40,
      expand=True
    ),
    expand=True,
    bgcolor=ft.Colors.SURFACE,
    padding=ft.padding.only(10, 4, 4, 4)
  )

  # Message display logic — ChatWindow is a @ft.component so this entire function
  # re-runs whenever any prop changes, including streaming_text on every token.
  # While streaming, override the last (empty) AI message with the live text.
  display_messages = list(messages or [])
  if is_streaming and streaming_text and display_messages and display_messages[-1].type == 'ai':
    # Shallow-copy the last message with the current streamed content so the
    # original message object in state is not mutated.
    last = display_messages[-1]
    live = AIMessage(content=streaming_text, timestamp=last.timestamp)
    display_messages = display_messages[:-1] + [live]

  _bubbles = [MessageBubble(m) for m in display_messages]

  message_list = ft.ListView(
    controls=_bubbles,
    spacing=15,
    auto_scroll=True,
    expand=True,
    padding=ft.padding.only(0, 0, 0, 15)
  )

  # Notify the parent so it can hold a ref for imperative scroll_to calls.
  if on_list_mounted:
    on_list_mounted(message_list)

  def grid_change(e):
    """ Adjusts height and limits max height to 4 rows """
    max_rows = 4
    grid_view_aspect_ratio = 4
    row_items = ceil(e.width / 160)
    items = len(e.control.controls)
    item_width = e.width / row_items
    item_height = item_width / grid_view_aspect_ratio # Aspect ratio for GridView is set to 4
    rows = ceil(items / row_items)

    # Calculate row height
    if rows > max_rows:
      set_height(item_height * 4 + 4 * 3) # 4 items + 3 spaces
    elif rows == 1:
      set_height(item_height)
    else:
      set_height(item_height * rows + 4 * (rows - 1))


  def make_chip(a: dict) -> ft.Container:
    """ Build attachment chips from live state """
    icon = ft.Icons.FOLDER_OPEN_OUTLINED if a["type"] == "folder" else ft.Icons.INSERT_DRIVE_FILE_OUTLINED
    path = a["path"]
    return Chip(
      icon=icon,
      delete=True,
      label=a["name"],
      on_delete=lambda _, p=path: remove_attachment(p)
    )

  attachment_chips: list[ft.Control] = [make_chip(a) for a in attachments]

  # Returns the chat window content
  return ft.Stack(
    [
      # Chat thread messages
      ft.Container(
        content=ft.ShaderMask(
          content=ft.SelectionArea(content=message_list) if llm_configured() else ft.Text("Configure LLM"),
          blend_mode=ft.BlendMode.DST_IN,
          # border_radius=10, # No effect
          shader=ft.LinearGradient(
            begin=ft.Alignment.TOP_CENTER,
            end=ft.Alignment.BOTTOM_CENTER,
            colors=[ft.Colors.BLACK, ft.Colors.TRANSPARENT],
            stops=[0.95, 1.0],
          )
        ),
        padding=ft.padding.only(0, 48, 0, 102),
        expand=True,
        alignment=ft.Alignment.TOP_CENTER
      ),

      # Message form / Chatbox
      ft.Row(
        [
          ft.Stack(
            [
              ft.Column(
                [
                  ft.Container(
                    content=ft.Column(
                      [
                        ft.Container(
                          on_click=focus_message_form,
                          margin=ft.margin.only(0, 0, 0, 0),
                          padding=ft.padding.only(4, 4, 4, 4),
                          bgcolor=ft.Colors.SECONDARY_CONTAINER,
                          # padding=ft.padding.only(4, -5, 4, 4),
                          border_radius=ft.BorderRadius(3, 3, 3, 3),
                          content=ft.Column(
                            [
                              # Attachments row — only visible when there are attachments
                              ft.Container(
                                ft.GridView(
                                  attachment_chips,
                                  spacing=4,
                                  height=height,
                                  run_spacing=4,
                                  max_extent=160, # Limits the width of the child
                                  child_aspect_ratio=4,
                                  semantic_child_count=4,
                                  size_change_interval=4,
                                  scroll=ft.ScrollMode.ADAPTIVE,
                                  clip_behavior=ft.ClipBehavior.HARD_EDGE,
                                  on_size_change=grid_change,
                                ),
                                expand_loose=True,
                                visible=len(attachments) > 0
                              ),

                              # Message input form row
                              # Textfield has built in padding that may make it look weird
                              ft.Container(
                                ft.TextField(
                                  margin=ft.Margin.all(0),
                                  expand=True,
                                  min_lines=1,
                                  max_lines=10,
                                  autofocus=True,
                                  border_radius=0,
                                  shift_enter=True,
                                  value=message_text,
                                  on_submit=handle_submit,
                                  border=ft.InputBorder.NONE,
                                  hint_text="Type a message...",
                                  border_color=ft.Colors.TRANSPARENT,
                                  hint_style=ft.TextStyle(weight=ft.FontWeight.NORMAL),
                                  on_change=lambda e: set_message_text(e.control.value)
                                ),
                                margin=ft.Margin.only(top=-5)
                              ),

                              # Button row
                              ft.Row(
                                [
                                  ft.Row(
                                    [
                                      PopupMenuButton(
                                        menu_items=[
                                          ft.PopupMenuItem(
                                            content=ft.Row(
                                              [
                                                ft.Icon(
                                                  size=16,
                                                  color=ft.Colors.PRIMARY,
                                                  icon=ft.Icons.FOLDER_OPEN_OUTLINED
                                                ),
                                                ft.Text("Add folder"),
                                              ],
                                              spacing=4
                                            ),
                                            on_click=handle_pick_folder,
                                          ),

                                          ft.PopupMenuItem(
                                            content=ft.Row(
                                              [
                                                ft.Icon(
                                                  ft.Icons.INSERT_DRIVE_FILE_OUTLINED,
                                                  size=16,
                                                  color=ft.Colors.PRIMARY,
                                                ),
                                                ft.Text("Add files"),
                                              ],
                                              spacing=4
                                            ),
                                            on_click=handle_pick_files,
                                          )
                                        ],
                                        icon=ft.Icons.ATTACH_FILE,
                                        tooltip="Add File/Folder"
                                      ),
                                      
                                      # Tool Menu
                                      # ToolMenu(settings={}, load_tools=lambda: print("Load tools")),

                                      # Model Menu
                                      PopupMenuButton(
                                        menu_items=[
                                          ft.PopupMenuItem(
                                            content=ft.Row(
                                              [
                                                ft.Icon(
                                                  ft.Icons.CHECK if (selected_model_config and cfg.get("id") == selected_model_config.get("id")) else ft.Icons.CIRCLE_OUTLINED,
                                                  size=14,
                                                  color=ft.Colors.PRIMARY,
                                                ),
                                                ft.Text(
                                                  cfg.get("alias") or cfg.get("model") or cfg.get("id", "Unknown"),
                                                  size=13,
                                                ),
                                              ],
                                              spacing=6,
                                            ),
                                            on_click=lambda e, c=cfg: on_model_select(c) if on_model_select else None,
                                          )
                                          for cfg in (model_configs or [])
                                        ],
                                        src='ai_sparkle.svg',
                                        tooltip=(
                                          selected_model_config.get("alias") or
                                          selected_model_config.get("model") or
                                          "Select model"
                                        ) if selected_model_config else "Select model"
                                      )
                                    ],
                                    spacing=4,
                                    expand=True
                                  ),
                                  # Send message button
                                  IconButton(
                                    icon=ft.Icons.SEND_ROUNDED if not is_streaming else ft.Icons.HOURGLASS_EMPTY_ROUNDED,
                                    tooltip="Send message" if not is_streaming else "Waiting for response…",
                                    on_click=handle_submit if not is_streaming else lambda e: None,
                                  )
                                ],
                                spacing=0
                              )
                            ],
                            spacing=0,
                            margin=ft.margin.only(0, 0, 0, 0),
                            alignment=ft.MainAxisAlignment.CENTER,
                            horizontal_alignment=ft.CrossAxisAlignment.END
                          )
                        )
                      ],
                      spacing=0,
                      alignment=ft.MainAxisAlignment.END,
                      horizontal_alignment=ft.CrossAxisAlignment.CENTER
                    ),
                    width=750,
                    bgcolor=ft.Colors.SURFACE,
                    alignment=ft.Alignment.BOTTOM_CENTER,
                    padding = ft.padding.only(13, 0, 15, 15),
                  )
                ],
                spacing=0,
                alignment=ft.MainAxisAlignment.END,
              )
            ],
            expand=True,
            alignment=ft.Alignment.BOTTOM_CENTER,
            clip_behavior=ft.ClipBehavior.ANTI_ALIAS
          )
        ],
        spacing=0,
        expand=True,
        alignment=ft.MainAxisAlignment.CENTER
      ),
      # Chat thread header
      chatwindow_header if llm_configured() else ft.Container(),
    ]
  )
