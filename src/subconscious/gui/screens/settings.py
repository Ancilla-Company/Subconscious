import uuid
import json
import asyncio
import flet as ft

from ..components.buttons import IconButton, TextButton
from ..components.layout import ResponsiveParent, ResponsiveItem
from ..components.forms import FormField, PasswordField, DropdownField


@ft.component
def General(settings: dict = None, on_setting_change=None) -> ft.Control:
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
def Model(settings: dict = None, on_setting_change=None) -> ft.Control:
  """ Renders the model settings panel """
  if settings is None:
    settings = {}

  # Parse model configurations from settings
  # Expected format in settings:
  # models: "[{\"id\": \"uuid\", \"provider\": \"...\", \"model\": \"...\", \"api_key\": \"...\", \"alias\": \"...\"}, ...]"
  try:
    models_data = json.loads(settings.get("models", "[]"))
  except:
    models_data = []

  def update_models(new_models):
    pass
    # if on_setting_change:
    #   on_setting_change("models", json.dumps(new_models), "system")

  def add_model(e):
    new_model = {
      "id": str(uuid.uuid4()),
      "provider": "",
      "model": "",
      "api_key": "",
      "alias": ""
    }
    update_models([new_model] + models_data)

  def delete_model(model_id):
    update_models([m for m in models_data if m["id"] != model_id])

  def handle_change(model_id, field, value):
    new_models = []
    for m in models_data:
      if m["id"] == model_id:
        updated = m.copy()
        updated[field] = value
        new_models.append(updated)
      else:
        new_models.append(m)
    update_models(new_models)

  panel_content = ft.Column(
    [
      # Providers
      DropdownField(
        label="Providers",
        values=[
          ft.dropdown.Option("XAI"),
          ft.dropdown.Option("Groq"),
          ft.dropdown.Option("OpenAI"),
          ft.dropdown.Option("Google"),
          ft.dropdown.Option("Ollama"),
          ft.dropdown.Option("DeepSeek"),
          ft.dropdown.Option("MistralAI"),
          ft.dropdown.Option("Anthropic"),
          ft.dropdown.Option("Hugging Face")
        ],
        on_change=lambda _: print("Provider Changed"),
        hint="Select a provider"
      ),

      # Model Key
      FormField(
        label="Model",
        value=None,
        on_change=lambda _: print("Model Changed"),
        hint="Enter the model key"      
      ),

      # Provider API Secret
      PasswordField(
        label="API Key",
        value=None,
        on_change=lambda _: print("API Key Changed"),
        hint="Enter your API key"
      ),

      # Alias for Provider & API Key
      FormField(
        label="Alias",
        value=None,
        on_change=lambda _: print("Alias Changed"),
        hint="Enter a memmorable name for this configuration"
      ),

      # Save & Delete button
      ft.Row(
        [
          TextButton(
            on_click=lambda _: print("Save Button Clicked"),
            text="Save",
            icon=ft.Icons.SAVE_OUTLINED,
            visible=True
          ),
          ft.Container(
            ft.Row(
              [
                IconButton(
                  on_click=lambda _: print("Delete Clicked"),
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

  model_controls = []
  for m in models_data:
    model_id = m["id"]
    provider = m.get("provider", "")
    model_name = m.get("model", "")
    api_key = m.get("api_key", "")
    alias = m.get("alias", "")

    title_text = alias if alias else (f"{provider}-{model_name}" if provider or model_name else "New Model")

  panel = ft.ExpansionPanel(
    header=ft.Container(
      content=ft.Text(
        "Model",
        size=18,
        weight=ft.FontWeight.W_400
      ),
      padding=ft.padding.only(15, 10, 0, 0)
    ),
    content=ft.Container(
      content=panel_content,
      padding=ft.padding.all(0),
      border_radius=ft.border_radius.only(3, 3, 3, 3)
    ),
    can_tap_header=True,
    expanded=True,
  )

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
          padding=ft.padding.only(0, 4, 0, 0)
        ),
        ft.Column(
          [
            ft.ExpansionPanelList(
              expand_icon_color=ft.Colors.PRIMARY,

              elevation=0,
              divider_color=ft.Colors.SECONDARY_CONTAINER,
              expanded_header_padding=ft.padding.all(0),
              controls=[
                panel,
              ]
            )
          ],
          spacing=10,
          scroll=ft.ScrollMode.ADAPTIVE
        ),
      ],
      spacing=4
    ),
    padding=ft.padding.all(0),
    expand=True
  )


# @ft.component
# def Tools() -> ft.Control:
#   """ Renders the tool settings """
