import asyncio
import flet as ft

from ..components.buttons import IconButton
from ..components.messages import MessageBubble, HumanMessage, AIMessage


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
                width=30,
                height=30,
                top=5,
                left=5,
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
                # surface_tint_color=ft.Colors.TRANSPARENT,
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
      ft.TextButton("Refresh Tools", on_click=self.load_tools, icon=ft.Icons.REFRESH, height=30)
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
def ChatWindow(thread=None, messages=None, on_send_message=None) -> ft.Control:
  """ Handles the main chat window, including message display and input form """
  
  # Message state
  message_text, set_message_text = ft.use_state("")
  
  # Dummy state and logic to resolve rendering errors from older version
  def llm_configured(): return True
  def focus_message_form(e): pass

  async def handle_submit(e):
    if message_text.strip():
      user_msg_content = message_text
      set_message_text("")

      # Call parent on_send_message (for Engine/Skeleton logic)
      # This will now handle the state updates (Human message & AI Echo)
      if on_send_message:
        await on_send_message(user_msg_content)
  
  chat_name = thread.title if thread else "New Thread"
  chatwindow_header = ft.Container(
    ft.Row([
      ft.Text(chat_name, size=14, text_align=ft.TextAlign.LEFT, weight=ft.FontWeight.W_500, expand=True, color=ft.Colors.PRIMARY),
      ft.IconButton(
          icon=ft.Icons.MORE_VERT_ROUNDED,
          tooltip="More",
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
          on_click=lambda e: print("Show chat settings"),
        )
    ], expand=True, height=40),
    bgcolor=ft.Colors.SURFACE, expand=True, padding=ft.padding.only(10,4,4,4),
    border=ft.border.only(bottom=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER))
  )

  # Message display logic
  message_list = ft.ListView(
    controls=[MessageBubble(m) for m in (messages or [])],
    spacing=10,
    auto_scroll=True,
    expand=True
  )

  # Returns the chat window content
  return ft.Stack([
    # Chat thread messages
    ft.Container(
      content=ft.SelectionArea(content=message_list) if llm_configured() else ft.Text("Configure LLM"),
      padding=ft.padding.only(0, 48, 0, 106),
      expand=True,
      alignment=ft.Alignment.TOP_CENTER,
    ),

    # Message form / Chatbox
    ft.Row([
      ft.Stack([
        ft.Column([
          ft.Container(
            content=ft.Column([
              ft.Container(
                border_radius=ft.BorderRadius(3, 3, 3, 3),
                padding=ft.padding.only(4, -5, 4, 4),
                margin=ft.margin.only(0, 0, 0, 0),
                bgcolor=ft.Colors.SECONDARY_CONTAINER,
                on_click=focus_message_form,
                content=ft.Column(
                  [
                    # Message input form
                    ft.TextField(
                      value=message_text,
                      on_change=lambda e: set_message_text(e.control.value),
                      hint_text="Type a message...",
                      hint_style=ft.TextStyle(weight=ft.FontWeight.NORMAL),
                      autofocus=True,
                      shift_enter=True,
                      min_lines=1,
                      max_lines=5,
                      on_submit=handle_submit,
                      border=ft.InputBorder.NONE,
                      border_color=ft.Colors.TRANSPARENT,
                      border_radius=0,
                      expand=True,
                    ),
                    ft.Row([
                      ft.Row(
                        [
                          # Tool Menu
                          # ToolMenu(settings={}, load_tools=lambda: print("Load tools")),
                          
                          # Attach file button
                          # IconButton(
                          #   icon=ft.Icons.ATTACH_FILE,
                          #   tooltip="Attach file",
                          #   on_click=lambda e: print("Attach file placeholder"),
                          # ),
                        ],
                        spacing=4,
                        expand=True
                      ),
                      # Send message button
                      IconButton(
                        icon=ft.Icons.SEND_ROUNDED,
                        tooltip="Send message",
                        on_click=handle_submit,
                      ),
                    ], spacing=0),
                  ],
                  alignment=ft.MainAxisAlignment.CENTER,
                  horizontal_alignment=ft.CrossAxisAlignment.END, spacing=0,
                ),
              ),
              ], alignment=ft.MainAxisAlignment.END, horizontal_alignment=ft.CrossAxisAlignment.CENTER, spacing=0,
            ),
            width=784,
            padding = ft.padding.only(15, 4, 15, 15),
            alignment=ft.Alignment.BOTTOM_CENTER,
            bgcolor=ft.Colors.SURFACE,
          ),
        ], alignment=ft.MainAxisAlignment.END, spacing=0),
        ],
        alignment=ft.Alignment.BOTTOM_CENTER,
        expand=True,
        clip_behavior=ft.ClipBehavior.ANTI_ALIAS,
      ),
    ], expand=True, alignment=ft.MainAxisAlignment.CENTER, spacing=0),

    # Chat thread header
    chatwindow_header if llm_configured() else ft.Container(),
  ])