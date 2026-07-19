import json
import asyncio
import flet as ft

from .screens.chat import ChatWindow
from .screens.thread_settings import ThreadSettings
from ..shared.buttons import TextButton, WideTextButton
from ..shared.layout import ResponsiveItem, ResponsiveParent
from ..shared.tool_config import ToolToggleTree, SkillToggleList
from ..shared.settings import Models, About, General, Tools, Skills
from ..shared.forms import FormField, TextArea, CheckBox, DropdownField


@ft.component
def MainWindow(
  current_view: str = "default",
  workspace=None,
  workspace_mode="view",
  settings_mode="models",
  on_save_workspace=None,
  on_delete_workspace=None,
  thread=None,
  messages=None,
  streaming_text: str = "",
  on_list_mounted=None,
  on_send_message=None,
  is_streaming=False,
  settings=None,
  on_setting_change=None,
  model_configs=None,
  on_save_model=None,
  on_delete_model=None,
  model_expanded_indices=None,
  set_model_expanded_indices=None,
  skill_configs=None,
  on_save_skill=None,
  on_delete_skill=None,
  skill_expanded_indices=None,
  set_skill_expanded_indices=None,
  tool_configs=None,
  on_save_tool=None,
  on_delete_tool=None,
  tool_expanded_indices=None,
  set_tool_expanded_indices=None,
  update_available: bool = False,
  on_update=None,
  selected_model_config=None,
  on_model_select=None,
  initial_chatbox_text: str = "",
  initial_chatbox_attachments=None,
  on_chatbox_change=None,
  chatbox_restore_token: int = 0,
  active_workspace=None,
  tool_catalog=None,
  workspace_tools_config=None,
  workspace_skills_config=None,
  on_workspace_tools_change=None,
  on_workspace_skills_change=None,
  workspace_approval_config=None,
  on_workspace_approval_change=None,
  workspace_directories=None,
  on_workspace_directories_change=None,
  on_workspace_directory_refresh=None,
  on_workspace_directory_remove=None,
  workspace_semantic_graph=False,
  on_workspace_semantic_graph_change=None,
  workspace_default_model=None,
  on_workspace_default_model_change=None,
  on_open_thread_tools=None,
  on_open_thread_skills=None,
  # Thread settings overlay (name/description + tools/skills toggles)
  show_thread_settings=False,
  thread_settings_open_token=0,
  on_save_thread=None,
  on_thread_settings_back=None,
  thread_tools_config=None,
  thread_skills_config=None,
  thread_approval_config=None,
  on_thread_tools_change=None,
  on_thread_skills_change=None,
  on_thread_approval_change=None,
  data_dir=None,
) -> ft.Control:
  """ The main window for the UI """
  
  # Default placeholder if no content is provided or selected
  default_content = ft.Container(
    ft.Column(
      [
        ft.Image(
          src="/logo.svg",
          width=150, height=150,
          color=ft.Colors.GREY,
        ),
        ft.Text("Subconscious", size=35, color=ft.Colors.GREY, text_align=ft.TextAlign.CENTER),
      ],
      spacing=0,
      expand=True,
      alignment=ft.MainAxisAlignment.CENTER,
      horizontal_alignment=ft.CrossAxisAlignment.CENTER
    )
  )

  # Choose content based on navigation state
  content = default_content
  if current_view == "threads":
    # The chat and the Thread Settings screen are both kept mounted; we just
    # toggle which one is visible (show/hide) instead of swapping views. Only
    # one is visible at a time, and the hidden one takes no layout space, so the
    # chat keeps its state while we retain direct control over the view.
    settings_visible = bool(show_thread_settings) and thread is not None

    chat_layer = ft.Container(
      content=ChatWindow(
        key=f"chatwindow-{chatbox_restore_token}",
        thread=thread,
        messages=messages,
        streaming_text=streaming_text,
        on_list_mounted=on_list_mounted,
        on_send_message=on_send_message,
        is_streaming=is_streaming,
        model_configs=model_configs,
        selected_model_config=selected_model_config,
        on_model_select=on_model_select,
        initial_chatbox_text=initial_chatbox_text,
        initial_chatbox_attachments=initial_chatbox_attachments or [],
        on_chatbox_change=on_chatbox_change,
        chatbox_restore_token=chatbox_restore_token,
        active_workspace=active_workspace,
        on_open_thread_tools=on_open_thread_tools,
        on_open_thread_skills=on_open_thread_skills,
      ),
      expand=True,
      visible=not settings_visible,
    )

    settings_layer = ft.Container(
      content=ThreadSettings(
        thread=thread,
        open_token=thread_settings_open_token,
        tool_catalog=tool_catalog,
        tool_configs=tool_configs,
        skill_configs=skill_configs,
        tools_config=thread_tools_config,
        skills_config=thread_skills_config,
        approval_config=thread_approval_config,
        on_save=on_save_thread,
        on_back=on_thread_settings_back,
        on_tools_change=on_thread_tools_change,
        on_skills_change=on_thread_skills_change,
        on_approval_change=on_thread_approval_change,
      ) if thread is not None else ft.Container(),
      expand=True,
      visible=settings_visible,
      bgcolor=ft.Colors.SURFACE,
    )

    content = ft.Column([chat_layer, settings_layer], expand=True, spacing=0)
  elif current_view == "settings":
    if settings_mode == "general":
      content = ft.Container(
        content=ResponsiveParent(
          [
            ResponsiveItem(
              General(
                settings=settings,
                on_setting_change=on_setting_change,
                data_dir=data_dir
              )
            ),
          ]
        ),
        expand=True
      )
    elif settings_mode == "models":
      content = ft.Container(
        content=ResponsiveParent(
          [
            ResponsiveItem(
              Models(
                settings=settings,
                on_setting_change=on_setting_change,
                model_configs=model_configs,
                on_save_model=on_save_model,
                on_delete_model=on_delete_model,
                expanded_indices=model_expanded_indices,
                set_expanded_indices=set_model_expanded_indices
              )
            ),
          ]
        ),
        expand=True
      )
    elif settings_mode == "tools":
      content = ft.Container(
        content=ResponsiveParent(
          [
            ResponsiveItem(
              Tools(
                settings=settings,
                on_setting_change=on_setting_change,
                tool_configs=tool_configs,
                on_save_tool=on_save_tool,
                on_delete_tool=on_delete_tool,
                expanded_indices=tool_expanded_indices,
                set_expanded_indices=set_tool_expanded_indices
              )
            ),
          ]
        ),
        expand=True
      )
    elif settings_mode == "skills":
      content = ft.Container(
        content=ResponsiveParent(
          [
            ResponsiveItem(
              Skills(
                settings=settings,
                on_setting_change=on_setting_change,
                skill_configs=skill_configs,
                on_save_skill=on_save_skill,
                on_delete_skill=on_delete_skill,
                expanded_indices=skill_expanded_indices,
                set_expanded_indices=set_skill_expanded_indices
              )
            ),
          ]
        ),
        expand=True
      )
    elif settings_mode == "about":
      content = ft.Container(
        content=About(
          settings=on_setting_change,
          on_update=on_update,
          update_available=update_available,
        ),
        expand=True
      )
    else:
      content = ft.Container(
        content=ft.Text("Select a settings category", size=16, color=ft.Colors.GREY_500),
        alignment=ft.Alignment.CENTER,
        expand=True
      )
  elif current_view == "workspaces":
    if workspace_mode in ["create", "edit"]:
      ws_name, set_ws_name = ft.use_state(workspace.name if workspace else "")
      ws_description, set_ws_description = ft.use_state(workspace.description if workspace else "")
      
      def sync_workspace_state():
        set_ws_name(workspace.name if workspace and workspace.name else "")
        set_ws_description(workspace.description if workspace and workspace.description else "")
        
      ft.use_effect(sync_workspace_state, [workspace, workspace_mode])

      def save_ws(e):
        if on_save_workspace:
          asyncio.create_task(on_save_workspace(ws_name, ws_description, workspace.id if workspace else None))

      def delete_ws(e):
        if on_delete_workspace and workspace:
          asyncio.create_task(on_delete_workspace(workspace.id))

      # ── Attached directories ────────────────────────────────────────────
      dir_picker = ft.FilePicker()

      def add_directory(e):
        async def _pick():
          res = await dir_picker.get_directory_path(dialog_title="Select a directory")
          # Newer Flet returns the path string directly; guard for object form too.
          path = getattr(res, "path", res) if res else None
          if not path:
            return
          current = list(workspace_directories or [])
          if path not in current:
            current.append(path)
            if on_workspace_directories_change:
              on_workspace_directories_change(current)
        asyncio.create_task(_pick())

      def remove_directory(path):
        # Prefer the confirm-gated remove handler; fall back to direct removal.
        if on_workspace_directory_remove:
          on_workspace_directory_remove(path)
          return
        current = [d for d in (workspace_directories or []) if d != path]
        if on_workspace_directories_change:
          on_workspace_directories_change(current)

      def refresh_directory(path):
        if on_workspace_directory_refresh:
          on_workspace_directory_refresh(path)

      def directory_row(path: str) -> ft.Control:
        return ft.Container(
          content=ft.Row(
            [
              ft.Icon(ft.Icons.FOLDER_OUTLINED, size=16, color=ft.Colors.PRIMARY),
              ft.Container(
                ft.Text(
                  path,
                  size=13,
                  expand=True,
                  tooltip=path,
                  no_wrap=True,
                  color=ft.Colors.PRIMARY,
                  overflow=ft.TextOverflow.ELLIPSIS,
                ),
                expand=True,
                padding=ft.Padding.only(left=5)
              ),
              ft.IconButton(
                icon=ft.Icons.REFRESH,
                icon_size=16,
                height=40,
                width=40,
                padding=0,
                tooltip="Refresh index for this directory",
                on_click=lambda e, p=path: refresh_directory(p),
                style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
              ),
              ft.IconButton(
                icon=ft.Icons.CLOSE,
                icon_size=16,
                height=40,
                width=40,
                padding=0,
                tooltip="Remove directory",
                on_click=lambda e, p=path: remove_directory(p),
                style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
              ),
            ],
            spacing=0,
            vertical_alignment=ft.CrossAxisAlignment.CENTER
          ),
          padding=ft.padding.only(10, 0, 0, 0),
          border_radius=ft.BorderRadius(3, 3, 3, 3),
          bgcolor=ft.Colors.SURFACE_CONTAINER_HIGHEST
        )

      def toggle_semantic_graph(e):
        if on_workspace_semantic_graph_change:
          on_workspace_semantic_graph_change(bool(e.control.value))

      directories_section = ft.Column(
        [
          ft.Container(
            content=ft.Text(
              "Directories",
              size=15,
              color=ft.Colors.PRIMARY,
            ),
            height=25
          ),
          WideTextButton(
            label="Add Directory",
            on_click=add_directory
          ),
          ft.Column(
            [directory_row(d) for d in (workspace_directories or [])],
            spacing=4,
          ),
          ft.Container(
            content=ft.Row(
              [
                ft.Column(
                  [
                    ft.Text("Build knowledge graph", size=14, color=ft.Colors.PRIMARY),
                    ft.Text(
                      "Use the model to extract entity relationships while indexing "
                      "(improves graph search over documents; uses model calls).",
                      size=11,
                      color=ft.Colors.ON_SURFACE_VARIANT,
                    ),
                  ],
                  spacing=2,
                  expand=True,
                ),
                ft.Switch(
                  value=bool(workspace_semantic_graph),
                  on_change=toggle_semantic_graph,
                ),
              ],
              vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            padding=ft.padding.only(2, 8, 2, 0),
          ),
        ],
        spacing=4
      )
        
      content = ft.Container(
        content=ResponsiveParent(
          [
            *[
              ResponsiveItem(
                ft.Container(
                  ft.Text(
                    "New Workspace" if workspace_mode == "create" else "Edit Workspace",
                    size=20,
                    weight=ft.FontWeight.W_500,
                    color=ft.Colors.PRIMARY,
                    expand=True
                  ),
                  height=40,
                  padding=ft.padding.only(0, 6, 0 , 0),
                  margin=ft.margin.only(0, 4, 0, 4)
                )
              ),
              ResponsiveItem(
                FormField(
                  label="Name",
                  value=ws_name,
                  on_change=lambda e: set_ws_name(e.control.value),
                  hint="Enter a name for your workspace"
                )
              ),
              ResponsiveItem(
                TextArea(
                  label="Description",
                  value=ws_description,
                  on_change=lambda e: set_ws_description(e.control.value),
                  hint="Enter a description for your workspace"
                )
              ),
              ResponsiveItem(
                DropdownField(
                  label="Default model",
                  values=[
                    ft.dropdown.Option(
                      c.get("id"),
                      c.get("alias") or c.get("model") or c.get("id"),
                    )
                    for c in (model_configs or [])
                  ],
                  # Fall back to the first config so the control always shows
                  # the model new threads will actually use.
                  value=workspace_default_model
                    or ((model_configs or [{}])[0].get("id") if model_configs else None),
                  on_change=(
                    lambda e: on_workspace_default_model_change(e.control.value)
                  ) if on_workspace_default_model_change else (lambda e: None),
                  hint="Model used for new threads in this workspace",
                )
              ) if (workspace_mode == "edit" and model_configs) else ResponsiveItem(ft.Container()),
            ],
            *[
              ResponsiveItem(directories_section)
            ],
            # ResponsiveItem(directories_section) if workspace_mode == "edit" else ResponsiveItem(ft.Container()),
            *[
              ResponsiveItem(
                ToolToggleTree(
                  catalog=tool_catalog or {},
                  configured_tools=tool_configs or [],
                  config=workspace_tools_config or {},
                  on_change=on_workspace_tools_change,
                  approval_config=workspace_approval_config or {},
                  on_approval_change=on_workspace_approval_change,
                  sync_key=workspace.id if workspace else "new",
                ),
              ) if workspace_mode == "edit" else ResponsiveItem(ft.Container()),
              ResponsiveItem(
                SkillToggleList(
                  skills=skill_configs or [],
                  config=workspace_skills_config or {},
                  on_change=on_workspace_skills_change,
                  sync_key=workspace.id if workspace else "new",
                ),
              ) if workspace_mode == "edit" else ResponsiveItem(ft.Container()),
              ResponsiveItem(
                ft.Row(
                  [
                    TextButton(on_click=save_ws, text="Save"),
                    TextButton(on_click=delete_ws, text="Delete") if workspace_mode == "edit" else ft.Container(),
                  ],
                  wrap=True,
                  spacing=4
                )
              )
            ]
          ]
        ),
        expand=True,
        padding=ft.Padding.only(bottom=15)
      )

    else:
      content = ft.Container(
        content=ft.Text("Select a workspace to view or edit", size=16, color=ft.Colors.GREY_500),
        alignment=ft.Alignment.CENTER,
        expand=True
      )
  elif current_view == "account":
    content = ft.Container(
      content=ft.Column(
        [
          ft.Icon(
            ft.Icons.PERSON_OUTLINED,
            size=64,
            color=ft.Colors.GREY_400
          ),
          ft.Text(
            "Account",
            size=24,
            weight=ft.FontWeight.W_500,
            color=ft.Colors.GREY_500
          ),
          ft.Text(
            "Login and profile management coming soon.",
            size=14,
            color=ft.Colors.GREY_500
          ),
        ],
        spacing=12,
        expand=True,
        alignment=ft.MainAxisAlignment.CENTER,
        horizontal_alignment=ft.CrossAxisAlignment.CENTER,
      ),
      expand=True,
    )
  else:
    content = default_content

  return ft.Container(
    content=content,
    padding=ft.padding.only(0, 0, 0, 0),
    expand=True,
    bgcolor=ft.Colors.SURFACE,
  )
