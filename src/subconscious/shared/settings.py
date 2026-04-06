import uuid
import asyncio
import flet as ft
from typing import Optional, cast

from ..constants import VERSION
from ..shared.buttons import IconButton, TextButton, Badge
from ..shared.forms import FormField, PasswordField, DropdownField


_PROVIDERS = [
  # Native pydantic-ai providers
  ft.dropdown.Option("Anthropic"),
  ft.dropdown.Option("Bedrock"),
  ft.dropdown.Option("Cerebras"),
  ft.dropdown.Option("Cohere"),
  ft.dropdown.Option("Gemini"),
  ft.dropdown.Option("Groq"),
  ft.dropdown.Option("Hugging Face"),
  ft.dropdown.Option("Mistral"),
  ft.dropdown.Option("OpenAI"),
  ft.dropdown.Option("OpenRouter"),
  ft.dropdown.Option("xAI"),
  # OpenAI-compatible providers
  ft.dropdown.Option("Alibaba Cloud Model Studio"),
  ft.dropdown.Option("Azure AI Foundry"),
  ft.dropdown.Option("DeepSeek"),
  ft.dropdown.Option("Fireworks AI"),
  ft.dropdown.Option("GitHub Models"),
  ft.dropdown.Option("LiteLLM"),
  ft.dropdown.Option("Nebius AI Studio"),
  ft.dropdown.Option("Ollama"),
  ft.dropdown.Option("Perplexity"),
  ft.dropdown.Option("SambaNova"),
  ft.dropdown.Option("Together AI"),
]


@ft.component
def ModelPanel(
  model: Optional[dict] = None,
  on_save=None,
  on_delete=None,
  expanded: bool = False,
) -> ft.ExpansionPanel:
  """A single expansion panel for one model configuration."""
  if model is None:
    model = {}

  model_id = model.get("id", str(uuid.uuid4()))

  # Local form state (mirrors the persisted model dict)
  provider, set_provider   = ft.use_state(model.get("provider", ""))
  model_key, set_model_key = ft.use_state(model.get("model", ""))
  api_key, set_api_key     = ft.use_state(model.get("api_key", ""))
  alias, set_alias         = ft.use_state(model.get("alias", ""))

  # Dirty flag — True once any field differs from the persisted values
  dirty, set_dirty = ft.use_state(False)

  # Track which model id we last synced from so we only reset state when a
  # genuinely different model is passed in (not on every parent re-render)
  synced_id, set_synced_id = ft.use_state("")

  # def sync_from_props():
  if model_id != synced_id:
    set_provider(model.get("provider", ""))
    set_model_key(model.get("model", ""))
    set_api_key(model.get("api_key", ""))
    set_alias(model.get("alias", ""))
    set_dirty(False)
    set_synced_id(model_id)

  # ft.use_effect(sync_from_props, [model_id])

  def mark_dirty(_):
    set_dirty(True)

  def handle_provider_change(e):
    set_provider(e.control.value)
    set_dirty(True)

  def handle_model_change(e):
    set_model_key(e.control.value)
    set_dirty(True)

  def handle_api_key_change(e):
    set_api_key(e.control.value)
    set_dirty(True)

  def handle_alias_change(e):
    set_alias(e.control.value)
    set_dirty(True)

  def handle_save(e):
    if on_save:
      asyncio.create_task(on_save({
        "id": model_id,
        "provider": provider,
        "model": model_key,
        "api_key": api_key,
        "alias": alias,
      }))
    set_dirty(False)

  def handle_delete(e):
    if on_delete:
      on_delete(model_id)

  # Derive display title for the panel header
  if alias:
    title_text = alias
  elif provider or model_key:
    title_text = f"{provider} – {model_key}".strip(" –")
  else:
    title_text = "New Model"

  panel_content = ft.Column(
    [
      DropdownField(
        label="Provider",
        values=_PROVIDERS,
        value=provider,
        on_change=handle_provider_change,
        hint="Select a provider"
      ),
      FormField(
        label="Model",
        value=model_key,
        on_change=handle_model_change,
        hint="Enter the model key"
      ),
      PasswordField(
        label="API Key",
        value=api_key,
        on_change=handle_api_key_change,
        hint="Enter your API key"
      ),
      FormField(
        label="Alias",
        value=alias,
        on_change=handle_alias_change,
        hint="Enter a memorable name for this configuration"
      ),
      ft.Row(
        [
          TextButton(
            on_click=handle_save,
            text="Save",
            icon=ft.Icons.SAVE_OUTLINED,
            visible=True,
            disabled=not dirty,
          ),
          ft.Container(
            ft.Row(
              [
                IconButton(
                  on_click=handle_delete,
                  icon=ft.Icons.DELETE_OUTLINE,
                  icon_colour=ft.Colors.ERROR,
                  tooltip="Delete configuration"
                )
              ],
              expand=True,
              wrap=True,
              alignment=ft.MainAxisAlignment.END,
            ),
            expand=True
          ),
        ],
        spacing=4
      )
    ],
    spacing=15,
    margin=ft.margin.only(15, 0, 15, 15)
  )

  return ft.ExpansionPanel(
    header=ft.Container(
      content=ft.Text(title_text, size=18, weight=ft.FontWeight.W_400),
      padding=ft.padding.only(15, 10, 0, 0)
    ),
    content=ft.Container(
      content=panel_content,
      padding=ft.padding.all(0),
      border_radius=ft.border_radius.only(3, 3, 3, 3)
    ),
    can_tap_header=True,
    expanded=expanded,
  )


@ft.component
def General(settings: Optional[dict] = None, on_setting_change=None) -> ft.Control:
  """ Renders the general settings """
  if settings is None:
    settings = {}

  tray = settings.get("tray", "True") == "True"
  theme_mode = settings.get("mode", "auto")

  async def handle_tray_change(e):
    await on_setting_change("tray", str(e.control.value), "system")

  async def handle_theme_change(e):
    await on_setting_change("mode", e.control.value, "system")

  _theme_options = [
    ft.dropdown.Option("auto", "System Default"),
    ft.dropdown.Option("light", "Light"),
    ft.dropdown.Option("dark", "Dark"),
  ]

  return ft.Container(
     content=ft.Column(
      [
        ft.Container(
          content=ft.Row(
            [
              ft.Text(
                "General Settings",
                size=20,
                weight=ft.FontWeight.W_500,
                expand=True
              )
            ],
            height=40
          ),
        ),
        ft.Column(
          [
            DropdownField(
              label="Theme Mode",
              values=_theme_options,
              on_change=handle_theme_change,
              value=theme_mode,
              hint="Selecte theme mode"
            )
          ],
          spacing=10,
          scroll=ft.ScrollMode.ADAPTIVE
        ),
      ],
      spacing=4
    )
  )


@ft.component
def Models(
  settings: Optional[dict] = None,
  on_setting_change=None,
  model_configs=None,
  on_save_model=None,
  on_delete_model=None,
  expanded_indices=None,
  set_expanded_indices=None,
) -> ft.Control:
  """ Renders the model settings panel """
  if settings is None:
    settings = {}
  if model_configs is None:
    model_configs = []
  if expanded_indices is None:
    expanded_indices = set()

  def _set_expanded(new_set):
    if set_expanded_indices:
      set_expanded_indices(new_set)

  def handle_panel_change(e):
    idx = int(e.data)
    new_set = set(expanded_indices)
    if idx in new_set:
      new_set.discard(idx)
    else:
      new_set.add(idx)
    _set_expanded(new_set)

  def add_model(e):
    # Expand index 0 immediately (new model will appear at the top)
    # Shift all existing expanded indices up by one to stay correct after prepend
    _set_expanded({i + 1 for i in expanded_indices} | {0})
    new_model = {
      "id": str(uuid.uuid4()),
      "provider": "",
      "model": "",
      "api_key": "",
      "alias": "",
    }
    if on_save_model:
      asyncio.create_task(on_save_model(new_model))

  def handle_delete_model(model_id: str):
    # Find the reversed index of the deleted model so we can update expanded_indices after confirm
    reversed_configs = list(reversed(model_configs))
    deleted_idx = next(
      (i for i, m in enumerate(reversed_configs) if m.get("id") == model_id),
      None
    )

    def on_confirmed():
      if deleted_idx is not None:
        # Remove deleted index and shift down any above it
        _set_expanded({
          i - 1 if i > deleted_idx else i
          for i in expanded_indices
          if i != deleted_idx
        })

    if on_delete_model:
      on_delete_model(model_id, on_confirmed)

  panels: list[ft.ExpansionPanel] = cast(list[ft.ExpansionPanel], [
    ModelPanel(
      model=m,
      on_save=on_save_model,
      on_delete=handle_delete_model,
      expanded=(i in expanded_indices),
    )
    for i, m in enumerate(reversed(model_configs))
  ])

  def panel_change(e):
    handle_panel_change(e)

  return ft.Container(
    content=ft.Column(
      [
        ft.Container(
          content=ft.Row(
            [
              ft.Text(
                "Models",
                size=20,
                weight=ft.FontWeight.W_500,
                expand=True
              ),
              TextButton(
                on_click=add_model,
                text="Add Model",
                icon=ft.Icons.ADD
              )
            ],
            height=40
          ),
        ),
        ft.Column(
          [
            ft.ExpansionPanelList(
              expand_icon_color=ft.Colors.PRIMARY,
              elevation=0,
              divider_color=ft.Colors.SECONDARY_CONTAINER,
              expanded_header_padding=ft.padding.all(0),
              controls=panels,
              on_change=panel_change
            )
          ],
          spacing=10,
          scroll=ft.ScrollMode.ADAPTIVE
        ),
      ],
      spacing=4
    ),
    padding=ft.padding.only(0, 4, 0, 4),
    expand=True
  )

_SOURCE_TYPES = [
  ft.dropdown.Option("folder", "Local Folder"),
  ft.dropdown.Option("zip",    "Zip Package"),
  ft.dropdown.Option("url",    "URL / Git"),
]

_TOOL_TYPES = [
  ft.dropdown.Option("script", "Script (Python / JS / TS)"),
  ft.dropdown.Option("mcp",    "MCP Server"),
  ft.dropdown.Option("api",    "REST / API Endpoint"),
]

_SCRIPT_LANGUAGES = [
  ft.dropdown.Option("python",     "Python"),
  ft.dropdown.Option("javascript", "JavaScript"),
  ft.dropdown.Option("typescript", "TypeScript"),
]

_AUTH_TYPES = [
  ft.dropdown.Option("",        "None"),
  ft.dropdown.Option("api_key", "API Key"),
  ft.dropdown.Option("oauth",   "OAuth"),
]

_STATUS_COLOURS = {
  "valid":   ft.Colors.GREEN,
  "invalid": ft.Colors.ERROR,
  "error":   ft.Colors.ERROR,
  "pending": ft.Colors.GREY,
  "active":  ft.Colors.GREEN,
  "disabled": ft.Colors.GREY,
}


@ft.component
def SkillPanel(
  skill: Optional[dict] = None,
  on_save=None,
  on_delete=None,
  expanded: bool = False,
) -> ft.ExpansionPanel:
  """A single expansion panel for one skill configuration."""
  if skill is None:
    skill = {}

  skill_id = skill.get("id", str(uuid.uuid4()))

  source,      set_source      = ft.use_state(skill.get("source", ""))
  source_type, set_source_type = ft.use_state(skill.get("source_type", "folder"))
  alias,       set_alias       = ft.use_state(skill.get("alias", ""))
  status,      set_status      = ft.use_state(skill.get("status", "pending"))
  req_tools,   set_req_tools   = ft.use_state(skill.get("required_tools", ""))
  dirty,       set_dirty       = ft.use_state(False)
  synced_id,   set_synced_id   = ft.use_state("")

  if skill_id != synced_id:
    set_source(skill.get("source", ""))
    set_source_type(skill.get("source_type", "folder"))
    set_alias(skill.get("alias", ""))
    set_status(skill.get("status", "pending"))
    set_req_tools(skill.get("required_tools", ""))
    set_dirty(False)
    set_synced_id(skill_id)

  def handle_source_change(e):
    set_source(e.control.value)
    set_dirty(True)

  def handle_source_type_change(e):
    set_source_type(e.control.value)
    set_dirty(True)

  def handle_alias_change(e):
    set_alias(e.control.value)
    set_dirty(True)

  def handle_save(e):
    if on_save:
      asyncio.create_task(on_save({
        "id": skill_id,
        "source": source,
        "source_type": source_type,
        "alias": alias,
        "status": status,
        "required_tools": req_tools,
      }))
    set_dirty(False)

  def handle_delete(e):
    if on_delete:
      on_delete(skill_id)

  # Derive title
  if alias:
    title_text = alias
  elif source:
    title_text = source.rstrip("/\\").split("/")[-1].split("\\")[-1] or source
  else:
    title_text = "New Skill"

  status_colour = _STATUS_COLOURS.get(status, ft.Colors.GREY)

  # Parse required_tools JSON list for chip display
  import json as _json
  try:
    tools_list: list[str] = _json.loads(req_tools) if req_tools else []
  except Exception:
    tools_list = []

  required_tools_section = ft.Column(
    [
      ft.Text("Required Tools", size=12, color=ft.Colors.GREY),
      ft.Row(
        [ft.Chip(label=ft.Text(t, size=12)) for t in tools_list]
        if tools_list
        else [ft.Text("None detected yet", size=12, color=ft.Colors.GREY_400)],
        wrap=True,
        spacing=4,
      ),
    ],
    spacing=4,
    visible=(status == "valid"),
  )

  panel_content = ft.Column(
    [
      DropdownField(
        label="Source Type",
        values=_SOURCE_TYPES,
        value=source_type,
        on_change=handle_source_type_change,
        hint="Select source type"
      ),
      FormField(
        label="Source",
        value=source,
        on_change=handle_source_change,
        hint="URL, path to zip file, or local folder path"
      ),
      FormField(
        label="Alias",
        value=alias,
        on_change=handle_alias_change,
        hint="Memorable name for this skill"
      ),
      ft.Row(
        [
          ft.Icon(ft.Icons.CIRCLE, size=10, color=status_colour),
          ft.Text(status.capitalize(), size=12, color=status_colour),
        ],
        spacing=4,
      ),
      required_tools_section,
      ft.Row(
        [
          TextButton(
            on_click=handle_save,
            text="Save & Validate",
            icon=ft.Icons.SAVE_OUTLINED,
            disabled=not dirty,
          ),
          ft.Container(
            ft.Row(
              [
                IconButton(
                  on_click=handle_delete,
                  icon=ft.Icons.DELETE_OUTLINE,
                  icon_colour=ft.Colors.ERROR,
                  tooltip="Remove skill"
                )
              ],
              expand=True,
              wrap=True,
              alignment=ft.MainAxisAlignment.END,
            ),
            expand=True
          ),
        ],
        spacing=4
      )
    ],
    spacing=15,
    margin=ft.margin.only(15, 0, 15, 15)
  )

  return ft.ExpansionPanel(
    header=ft.Container(
      content=ft.Row(
        [
          ft.Text(title_text, size=18, weight=ft.FontWeight.W_400, expand=True),
          ft.Icon(ft.Icons.CIRCLE, size=10, color=status_colour),
        ],
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
      ),
      padding=ft.padding.only(15, 10, 10, 0)
    ),
    content=ft.Container(
      content=panel_content,
      padding=ft.padding.all(0),
      border_radius=ft.border_radius.only(3, 3, 3, 3)
    ),
    can_tap_header=True,
    expanded=expanded,
  )

@ft.component
def Skills(
  settings: Optional[dict] = None,
  on_setting_change=None,
  skill_configs=None,
  on_save_skill=None,
  on_delete_skill=None,
  expanded_indices=None,
  set_expanded_indices=None,
) -> ft.Control:
  """ Renders the skills settings panel """
  if settings is None:
    settings = {}
  if skill_configs is None:
    skill_configs = []
  if expanded_indices is None:
    expanded_indices = set()

  def _set_expanded(new_set):
    if set_expanded_indices:
      set_expanded_indices(new_set)

  def handle_panel_change(e):
    idx = int(e.data)
    new_set = set(expanded_indices)
    if idx in new_set:
      new_set.discard(idx)
    else:
      new_set.add(idx)
    _set_expanded(new_set)

  def add_skill(e):
    _set_expanded({i + 1 for i in expanded_indices} | {0})
    new_skill = {
      "id": str(uuid.uuid4()),
      "source": "",
      "source_type": "folder",
      "alias": "",
      "status": "pending",
      "required_tools": "",
    }
    if on_save_skill:
      asyncio.create_task(on_save_skill(new_skill))

  def handle_delete_skill(skill_id: str):
    reversed_configs = list(reversed(skill_configs))
    deleted_idx = next(
      (i for i, s in enumerate(reversed_configs) if s.get("id") == skill_id),
      None
    )

    def on_confirmed():
      if deleted_idx is not None:
        _set_expanded({
          i - 1 if i > deleted_idx else i
          for i in expanded_indices
          if i != deleted_idx
        })

    if on_delete_skill:
      on_delete_skill(skill_id, on_confirmed)

  panels: list[ft.ExpansionPanel] = cast(list[ft.ExpansionPanel], [
    SkillPanel(
      skill=s,
      on_save=on_save_skill,
      on_delete=handle_delete_skill,
      expanded=(i in expanded_indices),
    )
    for i, s in enumerate(reversed(skill_configs))
  ])

  def panel_change(e):
    handle_panel_change(e)

  return ft.Container(
    content=ft.Column(
      [
        ft.Container(
          content=ft.Row(
            [
              ft.Text(
                "Skills",
                size=20,
                weight=ft.FontWeight.W_500,
                expand=True
              ),
              TextButton(
                on_click=add_skill,
                text="Add Skill",
                icon=ft.Icons.ADD
              )
            ],
            height=40
          ),
        ),
        ft.Column(
          [
            ft.ExpansionPanelList(
              expand_icon_color=ft.Colors.PRIMARY,
              elevation=0,
              divider_color=ft.Colors.SECONDARY_CONTAINER,
              expanded_header_padding=ft.padding.all(0),
              controls=panels,
              on_change=panel_change
            )
          ],
          spacing=10,
          scroll=ft.ScrollMode.ADAPTIVE
        ),
      ],
      spacing=4
    ),
    padding=ft.padding.only(0, 4, 0, 4),
    expand=True
  )


@ft.component
def ToolPanel(
  tool: Optional[dict] = None,
  on_save=None,
  on_delete=None,
  expanded: bool = False,
) -> ft.ExpansionPanel:
  """A single expansion panel for one tool configuration."""
  if tool is None:
    tool = {}

  tool_id = tool.get("id", str(uuid.uuid4()))

  alias,           set_alias           = ft.use_state(tool.get("alias", ""))
  tool_type,       set_tool_type       = ft.use_state(tool.get("tool_type", "script"))
  script_path,     set_script_path     = ft.use_state(tool.get("script_path", ""))
  script_language, set_script_language = ft.use_state(tool.get("script_language", "python"))
  endpoint_url,    set_endpoint_url    = ft.use_state(tool.get("endpoint_url", ""))
  auth_type,       set_auth_type       = ft.use_state(tool.get("auth_type", ""))
  auth_env_var,    set_auth_env_var    = ft.use_state(tool.get("auth_env_var", ""))
  api_key,         set_api_key         = ft.use_state(tool.get("api_key", ""))
  dirty,           set_dirty           = ft.use_state(False)
  synced_id,       set_synced_id       = ft.use_state("")

  if tool_id != synced_id:
    set_alias(tool.get("alias", ""))
    set_tool_type(tool.get("tool_type", "script"))
    set_script_path(tool.get("script_path", ""))
    set_script_language(tool.get("script_language", "python"))
    set_endpoint_url(tool.get("endpoint_url", ""))
    set_auth_type(tool.get("auth_type", ""))
    set_auth_env_var(tool.get("auth_env_var", ""))
    set_api_key(tool.get("api_key", ""))
    set_dirty(False)
    set_synced_id(tool_id)

  def handle_tool_type_change(e):
    set_tool_type(e.control.value)
    set_dirty(True)

  def handle_script_language_change(e):
    set_script_language(e.control.value)
    set_dirty(True)

  def handle_auth_type_change(e):
    set_auth_type(e.control.value)
    set_dirty(True)

  def handle_save(e):
    if on_save:
      asyncio.create_task(on_save({
        "id": tool_id,
        "alias": alias,
        "tool_type": tool_type,
        "script_path": script_path,
        "script_language": script_language,
        "endpoint_url": endpoint_url,
        "auth_type": auth_type,
        "auth_env_var": auth_env_var,
        "api_key": api_key,
      }))
    set_dirty(False)

  def handle_delete(e):
    if on_delete:
      on_delete(tool_id)

  title_text = alias if alias else f"New {(tool_type or 'Tool').upper()} Tool"

  # Script fields (visible when tool_type == "script")
  script_fields = ft.Column(
    [
      DropdownField(
        label="Language",
        values=_SCRIPT_LANGUAGES,
        value=script_language,
        on_change=handle_script_language_change,
        hint="Script language"
      ),
      FormField(
        label="Script Path",
        value=script_path,
        on_change=lambda e: (set_script_path(e.control.value), set_dirty(True)),
        hint="Absolute or relative path to the script file"
      ),
    ],
    spacing=15,
    visible=(tool_type == "script")
  )

  # Endpoint field (visible when mcp or api)
  endpoint_fields = ft.Column(
    [
      FormField(
        label="Endpoint URL",
        value=endpoint_url,
        on_change=lambda e: (set_endpoint_url(e.control.value), set_dirty(True)),
        hint="https://..."
      ),
    ],
    spacing=15,
    visible=(tool_type in ("mcp", "api"))
  )

  # Auth fields
  auth_fields = ft.Column(
    [
      DropdownField(
        label="Auth Type",
        values=_AUTH_TYPES,
        value=auth_type,
        on_change=handle_auth_type_change,
        hint="Authentication method"
      ),
      FormField(
        label="Env Var Name",
        value=auth_env_var,
        on_change=lambda e: (set_auth_env_var(e.control.value), set_dirty(True)),
        hint="e.g. MY_TOOL_API_KEY  (set in environment at runtime)",
        visible=(auth_type == "api_key")
      ),
      PasswordField(
        label="API Key",
        value=api_key,
        on_change=lambda e: (set_api_key(e.control.value), set_dirty(True)),
        hint="Key value — stored encrypted",
        visible=(auth_type == "api_key")
      ),
      ft.Text(
        "OAuth is handled externally via environment variables.",
        size=12,
        color=ft.Colors.GREY,
        visible=(auth_type == "oauth")
      ),
    ],
    spacing=15,
  )

  panel_content = ft.Column(
    [
      FormField(
        label="Alias",
        value=alias,
        on_change=lambda e: (set_alias(e.control.value), set_dirty(True)),
        hint="Memorable name for this tool"
      ),
      DropdownField(
        label="Tool Type",
        values=_TOOL_TYPES,
        value=tool_type,
        on_change=handle_tool_type_change,
        hint="Type of tool"
      ),
      script_fields,
      endpoint_fields,
      auth_fields,
      ft.Row(
        [
          TextButton(
            on_click=handle_save,
            text="Save",
            icon=ft.Icons.SAVE_OUTLINED,
            disabled=not dirty,
          ),
          ft.Container(
            ft.Row(
              [
                IconButton(
                  on_click=handle_delete,
                  icon=ft.Icons.DELETE_OUTLINE,
                  icon_colour=ft.Colors.ERROR,
                  tooltip="Remove tool"
                )
              ],
              expand=True,
              wrap=True,
              alignment=ft.MainAxisAlignment.END,
            ),
            expand=True
          ),
        ],
        spacing=4
      )
    ],
    spacing=15,
    margin=ft.margin.only(15, 0, 15, 15)
  )

  return ft.ExpansionPanel(
    header=ft.Container(
      content=ft.Text(title_text, size=18, weight=ft.FontWeight.W_400),
      padding=ft.padding.only(15, 10, 0, 0)
    ),
    content=ft.Container(
      content=panel_content,
      padding=ft.padding.all(0),
      border_radius=ft.border_radius.only(3, 3, 3, 3)
    ),
    can_tap_header=True,
    expanded=expanded,
  )


@ft.component
def Tools(
  settings: Optional[dict] = None,
  on_setting_change=None,
  tool_configs=None,
  on_save_tool=None,
  on_delete_tool=None,
  expanded_indices=None,
  set_expanded_indices=None,
) -> ft.Control:
  """ Renders the tools settings panel """
  if settings is None:
    settings = {}
  if tool_configs is None:
    tool_configs = []
  if expanded_indices is None:
    expanded_indices = set()

  def _set_expanded(new_set):
    if set_expanded_indices:
      set_expanded_indices(new_set)

  def handle_panel_change(e):
    idx = int(e.data)
    new_set = set(expanded_indices)
    if idx in new_set:
      new_set.discard(idx)
    else:
      new_set.add(idx)
    _set_expanded(new_set)

  def add_tool(e):
    _set_expanded({i + 1 for i in expanded_indices} | {0})
    new_tool = {
      "id": str(uuid.uuid4()),
      "alias": "",
      "tool_type": "script",
      "script_path": "",
      "script_language": "python",
      "endpoint_url": "",
      "auth_type": "",
      "auth_env_var": "",
      "api_key": "",
    }
    if on_save_tool:
      asyncio.create_task(on_save_tool(new_tool))

  def handle_delete_tool(tool_id: str):
    reversed_configs = list(reversed(tool_configs))
    deleted_idx = next(
      (i for i, t in enumerate(reversed_configs) if t.get("id") == tool_id),
      None
    )

    def on_confirmed():
      if deleted_idx is not None:
        _set_expanded({
          i - 1 if i > deleted_idx else i
          for i in expanded_indices
          if i != deleted_idx
        })

    if on_delete_tool:
      on_delete_tool(tool_id, on_confirmed)

  panels: list[ft.ExpansionPanel] = cast(list[ft.ExpansionPanel], [
    ToolPanel(
      tool=t,
      on_save=on_save_tool,
      on_delete=handle_delete_tool,
      expanded=(i in expanded_indices),
    )
    for i, t in enumerate(reversed(tool_configs))
  ])

  def panel_change(e):
    handle_panel_change(e)

  return ft.Container(
    content=ft.Column(
      [
        ft.Container(
          content=ft.Row(
            [
              ft.Text(
                "Tools",
                size=20,
                weight=ft.FontWeight.W_500,
                expand=True
              ),
              TextButton(
                on_click=add_tool,
                text="Add Tool",
                icon=ft.Icons.ADD
              )
            ],
            height=40
          ),
        ),
        ft.Column(
          [
            ft.ExpansionPanelList(
              expand_icon_color=ft.Colors.PRIMARY,
              elevation=0,
              divider_color=ft.Colors.SECONDARY_CONTAINER,
              expanded_header_padding=ft.padding.all(0),
              controls=panels,
              on_change=panel_change
            )
          ],
          spacing=10,
          scroll=ft.ScrollMode.ADAPTIVE
        ),
      ],
      spacing=4
    ),
    padding=ft.padding.only(0, 4, 0, 4),
    expand=True
  )


@ft.component
def About(update_available: bool = False, on_update=None) -> ft.Control:
  """ Renders the about settings panel """

  async def handle_update(_):
    if on_update:
      await on_update()

  return ft.Container(
    content=ft.Column(
      [
        ft.Container(
          content=ft.Row(
            [
              ft.Container(
                ft.Icon(
                  ft.Icons.INFO_OUTLINE,
                  size=20,
                  color=ft.Colors.PRIMARY
                ),
                padding=ft.padding.only(0, 3, 0, 0)
              ),
              ft.Text(
                "About",
                size=20,
                weight=ft.FontWeight.W_500,
              )
            ],
            alignment=ft.MainAxisAlignment.CENTER,
            height=40,
            expand=True
          ),
        ),
        ft.Container(
        ft.Column(
          [
            ft.Container(
              ft.Row(
                [
                  ft.Column(
                    [
                      ft.Image(
                        src="./logo.svg",
                        width=100,
                        height=100,
                        color=ft.Colors.PRIMARY
                      ),
                      ft.Text(
                        "Subconscious",
                        size=20,
                        weight=ft.FontWeight.BOLD
                      )
                    ],
                    expand=True,
                    horizontal_alignment=ft.CrossAxisAlignment.CENTER
                  )
                ],
                alignment=ft.MainAxisAlignment.CENTER,
              ),
              margin=ft.margin.only(0, 0, 0, 60)
            ),
            ft.Text(
              "Subconscious is a distributed agentic AI app, that allows you to create AI agents that run everywhere on every device at the same time.",
              size=15,
              color=ft.Colors.GREY,
              text_align=ft.TextAlign.CENTER
            ),
            ft.Text(
              spans=[
                ft.TextSpan("Visit us at: "),
                ft.TextSpan(
                  "Subconscious.chat",
                  ft.TextStyle(decoration=ft.TextDecoration.UNDERLINE),
                  url="https://subconscious.chat/",
                )
              ],
              size=15
            ),
            ft.Text(
              spans=[
                ft.TextSpan(
                  "View License",
                  ft.TextStyle(decoration=ft.TextDecoration.UNDERLINE),
                  url="https://github.com/Ancilla-Company/Subconscious/blob/main/LICENSE",
                )
              ],
              size=15
            ),
            ft.Text(
              spans=[
                ft.TextSpan(
                  "Report an Issue",
                  ft.TextStyle(decoration=ft.TextDecoration.UNDERLINE),
                  url="https://github.com/Ancilla-Company/Subconscious/issues",
                )
              ],
              size=15
            ),
            ft.Text(
              f"Version: {VERSION}",
              size=15,
              color=ft.Colors.GREY
            ),
            TextButton(
              on_click=handle_update,
              text="Install Update",
              icon=ft.Icons.SYSTEM_UPDATE_ALT,
              visible=update_available,
              badge=Badge()
            ),
            ft.Text(
              "© 2026 Subconscious",
              size=15,
              color=ft.Colors.GREY,
            )    
          ],
          spacing=10,
          expand=True,
          scroll=ft.ScrollMode.ADAPTIVE,
          alignment=ft.MainAxisAlignment.CENTER,
          horizontal_alignment=ft.CrossAxisAlignment.CENTER
        ),
        expand=True,
        alignment=ft.Alignment.CENTER
        )
      ],
      spacing=4,
      expand=True
    ),
    expand=True,
    padding=ft.padding.only(15, 4, 15, 4)
  )
