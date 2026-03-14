import uuid
import asyncio
import flet as ft
from typing import Optional, cast

from ..components.buttons import IconButton, TextButton
from ..components.layout import ResponsiveParent, ResponsiveItem
from ..components.forms import FormField, PasswordField, DropdownField


_PROVIDERS = [
  ft.dropdown.Option("XAI"),
  ft.dropdown.Option("Groq"),
  ft.dropdown.Option("OpenAI"),
  ft.dropdown.Option("Google"),
  ft.dropdown.Option("Ollama"),
  ft.dropdown.Option("DeepSeek"),
  ft.dropdown.Option("MistralAI"),
  ft.dropdown.Option("Anthropic"),
  ft.dropdown.Option("Hugging Face"),
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

  def handle_tray_change(e):
    if on_setting_change:
      on_setting_change("tray", str(e.control.value), "general")

  return ft.Container(
    content=ResponsiveParent([
      ResponsiveItem(
        ft.Text("General Settings", size=20, weight=ft.FontWeight.W_500)
      ),
      ResponsiveItem(
        ft.Checkbox(
          label="Show tray icon",
          value=tray,
          on_change=handle_tray_change
        )
      ),
    ]),
    padding=ft.padding.all(20)
  )


@ft.component
def Model(
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
          # padding=ft.padding.only(0, 4, 0, 0)
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


# @ft.component
# def Tools() -> ft.Control:
#   """ Renders the tool settings """
