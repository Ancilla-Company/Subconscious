import flet as ft

from utilities.toolchange import ToolsQueue
from utilities.settingchange import SettingsQueue


class ToolItem(ft.PopupMenuItem):
  def __init__(self, settings, slug, thread_id=None, initialization=False):
    super().__init__()
    self.settings = settings
    self.error = False

    # Disabled for initialization or if there is an error with the tool
    if initialization:
      self.disabled = True
      self.error = True
    else:
      self.disabled = self.settings['_tools'][slug].get('error', False)
      self.error = self.settings['_tools'][slug].get('error', False)

    self.thread_id = thread_id # To track which thread was modified
    self.name = self.settings['_tools'][slug].get('name', "") if self.settings['_tools'][slug].get('name', "") != "" else "Tool"

    if thread_id:
      if str(thread_id) in self.settings['_thread_tools']:
        self.state = self.settings['_thread_tools'][str(thread_id)].get(slug, False)
      else:
        self.state = False
        self.settings['_thread_tools'][str(thread_id)] = {
          slug: False
        }
    else:
      self.state = False

    self.on_click
    self.content = ft.Container(ft.Row(
      controls=[
        ft.Switch(
          label=ft.Container(ft.Row([
            ft.Icon(ft.Icons.ERROR, size=30, color=ft.Colors.PRIMARY, visible=self.error, tooltip="Error"),
            ft.Text(self.name, size=20, expand=True)]), padding=ft.padding.only(left=20)
          ),
          value=self.state,
          disabled=self.disabled, # Switched to enabled once loaded
          on_change=self.toggle_tool, height=30
        )
      ],
    ), expand=True)
    self.data = slug
    self.height = 30

  async def toggle_tool(self, event):
    """ Initialize or remove the tool """
    # Update the tool's state in the settings
    val = event.data == 'true'
    if str(self.thread_id) in self.settings['_thread_tools']:
      self.settings['_thread_tools'][str(self.thread_id)][self.data] = val
    else:
      self.settings['_thread_tools'][str(self.thread_id)] = {
        self.data: val
      }

    await SettingsQueue.put(self.settings)
    await ToolsQueue.put((self.data, val, self.thread_id, "toggle"))

class ToolMenu(ft.Container):
  def __init__(self, settings, load_tools, thread_id=None):
    super().__init__()
    self.slugs = []
    self.visible=False
    self.settings = settings
    self.thread_id = thread_id
    self.load_tools = load_tools
    self.margin=ft.margin.only(0,0,4,4)
    self.padding=ft.padding.only(0,0,0,0)
    self.border_radius=ft.BorderRadius(3,3,3,3) # For some reason using 3 for all radii doesn't look right
    self.clip_behavior=ft.ClipBehavior.HARD_EDGE

    self.content=ft.Row([
      ft.Container(
        content=ft.Stack([
            ft.Image(
              src="./assets/tools.svg",
              width=30, height=30,
              top=5, left=5,
              color=ft.Colors.PRIMARY
            ),
            ft.PopupMenuButton(
              icon=None, shape=ft.RoundedRectangleBorder(radius=3), # Has no effect
              width=200, height=2000, left=-50, top=-50, splash_radius=35,
              icon_size=0, tooltip="Tools", surface_tint_color=ft.Colors.TRANSPARENT,
              items=[
                *self.load_tools_ui()
              ],
            ),
          ], clip_behavior=ft.ClipBehavior.HARD_EDGE,
          width=40, height=40
        ),
        padding=ft.padding.only(0,0,0,0),
      )
    ], height=40, width=40, spacing=0)

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

    for slug, config in reversed(self.settings['_tools'].items()):
      if config.get('url', "") != "":
        tools.append(ToolItem(self.settings, slug, initialization=True))
        self.slugs.append(slug)
    return tools

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
