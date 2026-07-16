import asyncio
import flet as ft

from ...shared.buttons import TextButton, IconButton
from ...shared.forms import FormField, TextArea
from ...shared.layout import ResponsiveItem, ResponsiveParent
from ...shared.tool_config import ToolToggleTree, SkillToggleList


@ft.component
def ThreadSettings(
  thread=None,
  open_token=0,
  tool_catalog=None,
  tool_configs=None,
  skill_configs=None,
  tools_config=None,
  skills_config=None,
  approval_config=None,
  on_save=None,
  on_back=None,
  on_tools_change=None,
  on_skills_change=None,
  on_approval_change=None,
) -> ft.Control:
  """Dedicated thread settings screen: edit the thread's name/description and,
  beneath that, its Tools & Skills toggles (mirrors the workspace edit form).

  This is its own component so its hooks (use_state/use_effect) are isolated
  from MainWindow. Rendering the hooks here — rather than inside a conditional
  branch of MainWindow — keeps MainWindow's hook order stable, so navigating
  back to the chat (unmounting this screen) works reliably, including after a
  save re-render.
  """
  name, set_name = ft.use_state(thread.title if thread else "")
  description, set_description = ft.use_state(thread.description if thread else "")

  def sync_state():
    # Re-seed the fields when the active thread changes (e.g. after a save
    # replaces the selected thread object, or switching threads) or when the
    # screen is (re)opened (open_token bump).
    set_name(thread.title if thread and thread.title else "")
    set_description(thread.description if thread and thread.description else "")

  ft.use_effect(sync_state, [thread, open_token])

  def save(e):
    if on_save and thread is not None:
      asyncio.create_task(on_save(name, description, thread.id))

  return ft.Container(
    content=ResponsiveParent(
      [
        ResponsiveItem(
          ft.Container(
            ft.Row(
              [
                IconButton(
                  icon=ft.Icons.ARROW_BACK,
                  tooltip="Back to chat",
                  on_click=on_back,
                ),
                ft.Text(
                  "Thread Settings",
                  size=20,
                  weight=ft.FontWeight.W_500,
                  color=ft.Colors.PRIMARY,
                  expand=True,
                ),
              ],
              spacing=6,
              vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            height=40,
            margin=ft.margin.only(0, 4, 0, 4),
          )
        ),
        ResponsiveItem(
          FormField(
            label="Name",
            value=name,
            on_change=lambda e: set_name(e.control.value),
            hint="Enter a name for this thread",
          )
        ),
        ResponsiveItem(
          TextArea(
            label="Description",
            value=description,
            on_change=lambda e: set_description(e.control.value),
            hint="Enter a description for this thread",
          )
        ),
        ResponsiveItem(
          ToolToggleTree(
            catalog=tool_catalog or {},
            configured_tools=tool_configs or [],
            config=tools_config or {},
            on_change=on_tools_change,
            approval_config=approval_config or {},
            on_approval_change=on_approval_change,
            sync_key=f"{thread.id if thread else 'none'}-{open_token}",
          )
        ),
        ResponsiveItem(
          SkillToggleList(
            skills=skill_configs or [],
            config=skills_config or {},
            on_change=on_skills_change,
            sync_key=f"{thread.id if thread else 'none'}-{open_token}",
          )
        ),
        ResponsiveItem(
          ft.Row(
            [TextButton(on_click=save, text="Save")],
            wrap=True,
            spacing=4,
          )
        ),
      ]
    ),
    expand=True,
    padding=ft.Padding.only(bottom=15),
  )
