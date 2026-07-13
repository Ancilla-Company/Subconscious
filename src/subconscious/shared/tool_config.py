"""
Reusable tool / skill toggle controls.

  tools_config  = {"builtin": {slug: {"enabled": bool, "tools": {name: bool}}},
                   "configured": {tool_uuid: bool}}
  skills_config = {skill_uuid: bool}

"""

import copy
import flet as ft


# Sentinel so the initial render does not trigger an unwanted resync.
_UNSET = object()


# Friendly display names for the built-in tool slugs.
_SLUG_LABELS = {
  "time":       "Time Tools",
  "calculator": "Calculator Tools",
  "weather":    "Weather Tools",
  "todo":       "To-Do Tools",
  "memory":     "Memory Tools",
  "notes":      "Notes Tools",
  "contacts":   "Contacts Tools",
  "web":        "Web Tools",
  "filesystem": "Filesystem Tools",
  "terminal":   "Terminal Tools",
  "clipboard":  "Clipboard Tools",
  "images":     "Image Tools",
  "settings":   "Settings Tools",
}


def _slug_label(slug: str) -> str:
  return _SLUG_LABELS.get(slug, slug.replace("_", " ").title() + " Tools")


def _tool_label(name: str) -> str:
  return name.replace("_", " ").title()


@ft.component
def ToolToggleTree(
  catalog=None,
  configured_tools=None,
  config=None,
  on_change=None,
  sync_key=None,
  approval_config=None,
  on_approval_change=None,
):
  """
  Hierarchical tool toggle list.

  Args:
    catalog:          {slug: [{"name": str, "doc": str}, ...]} from the registry.
    configured_tools: list of user-configured tool dicts (id/alias/tool_type).
    config:           current tools_config dict used to seed the toggle state.
    on_change:        callable(config) invoked after every toggle.
    sync_key:         identity of the config source (workspace/thread id). When
                      it changes the internal state resyncs from ``config`` so
                      switching context shows the correct toggles.
    approval_config:  current HITL approval policy {"query": bool, "mutation":
                      bool} (True == approval required) used to seed the toggles.
    on_approval_change: callable(approval_config) invoked after a toggle.
  """
  catalog = catalog or {}
  configured_tools = configured_tools or []

  _default_approval = {"query": True, "mutation": True}

  cfg, set_cfg = ft.use_state(config if config is not None else {})
  appr, set_appr = ft.use_state(
    dict(approval_config) if approval_config is not None else dict(_default_approval)
  )
  synced_key, set_synced_key = ft.use_state(_UNSET)

  # Resync when the identity key changes (e.g. a different workspace/thread).
  if sync_key != synced_key:
    cfg = config if config is not None else {}
    set_cfg(cfg)
    appr = dict(approval_config) if approval_config is not None else dict(_default_approval)
    set_appr(appr)
    set_synced_key(sync_key)

  def _emit(new_cfg):
    set_cfg(new_cfg)
    if on_change:
      on_change(new_cfg)

  def toggle_approval(kind, value):
    new = dict(appr)
    new[kind] = value
    set_appr(new)
    if on_approval_change:
      on_approval_change(new)

  def toggle_builtin_master(value):
    new = copy.deepcopy(cfg)
    new["builtin_enabled"] = value
    _emit(new)

  def toggle_configured_master(value):
    new = copy.deepcopy(cfg)
    new["configured_enabled"] = value
    _emit(new)

  def toggle_slug(slug, value):
    new = copy.deepcopy(cfg)
    new.setdefault("builtin", {}).setdefault(slug, {})["enabled"] = value
    _emit(new)

  def toggle_tool(slug, name, value):
    new = copy.deepcopy(cfg)
    new.setdefault("builtin", {}).setdefault(slug, {}).setdefault("tools", {})[name] = value
    _emit(new)

  def toggle_configured(uuid, value):
    new = copy.deepcopy(cfg)
    new.setdefault("configured", {})[uuid] = value
    _emit(new)

  builtin = cfg.get("builtin", {})
  configured = cfg.get("configured", {})
  # Master switches gate their whole section. Default True so unconfigured
  # workspaces/threads keep every tool enabled.
  builtin_master = cfg.get("builtin_enabled", True)
  configured_master = cfg.get("configured_enabled", True)

  rows: list = []

  # ---- Human-in-the-loop approval policy ------------------------------
  # Two independent gates: require the user to approve read (query) and/or
  # modify (mutation) tool calls before they run.
  rows.append(
    ft.Container(
      ft.Column(
        [
          ft.Text(
            "Require approval before the assistant runs tools",
            size=12, color=ft.Colors.SECONDARY,
          ),
          ft.Switch(
            height=30,
            value=appr.get("query", True),
            label=ft.Text("Reads / queries", size=18, expand=True),
            on_change=lambda e: toggle_approval("query", e.control.value),
          ),
          ft.Switch(
            height=30,
            value=appr.get("mutation", True),
            label=ft.Text("Writes / mutations", size=18, expand=True),
            on_change=lambda e: toggle_approval("mutation", e.control.value),
          ),
        ],
        spacing=0,
      ),
      padding=ft.padding.only(10, 6, 10, 6),
    )
  )
  rows.append(ft.Divider(height=1, color=ft.Colors.SECONDARY_CONTAINER))

  # ---- Built-in tools -------------------------------------------------
  # Each slug is its own ExpansionTile (a master switch that gates its
  # individual tool switches). All slug tiles live inside the "Builtin Tools"
  # master tile so the whole section collapses/expands together.
  slug_tiles: list = []
  for slug, tools in catalog.items():
    slug_cfg = builtin.get(slug, {})
    slug_enabled = slug_cfg.get("enabled", True)
    tool_states = slug_cfg.get("tools", {})

    subs: list = []
    for entry in tools:
      name = entry.get("name", "")
      subs.append(
        ft.Switch(
          height=30,
          # A sub-tool is disabled when its group is off OR the master is off.
          disabled=(not builtin_master) or (not slug_enabled),
          value=tool_states.get(name, True),
          tooltip=entry.get("doc", "") or None,
          label=ft.Text(_tool_label(name), size=20, expand=True),
          on_change=lambda e, s=slug, n=name: toggle_tool(s, n, e.control.value),
        )
      )

    slug_tiles.append(
      ft.ExpansionTile(
        title=ft.Column(
          [
            ft.Switch(
              height=30,
              disabled=not builtin_master,
              value=slug_enabled,
              label=_slug_label(slug),
              label_text_style=ft.TextStyle(size=20),
              on_change=lambda e, s=slug: toggle_slug(s, e.control.value),
            )
          ]
        ),
        expand=True,
        expanded=False,
        controls=[
          ft.Container(
            ft.Column(subs, spacing=0),
            padding=ft.padding.only(left=30),
          )
        ],
      )
    )

  if catalog:
    builtin_controls: list = [
      ft.Container(
        ft.Column(slug_tiles, spacing=0),
        padding=ft.padding.only(left=30),
      )
    ]
  else:
    builtin_controls = [
      ft.Container(
        ft.Text("No tools available.", size=13, color=ft.Colors.GREY),
        padding=ft.padding.only(left=30),
      )
    ]

  # Master toggle for all built-in (default) tools, wrapping every slug tile.
  rows.append(
    ft.ExpansionTile(
      title=ft.Column(
        [
          ft.Switch(
            height=30,
            value=builtin_master,
            label="Builtin Tools",
            label_text_style=ft.TextStyle(size=20),
            on_change=lambda e: toggle_builtin_master(e.control.value),
          )
        ]
      ),
      expand=True,
      expanded=False,
      controls=builtin_controls,
    )
  )

  # ---- Custom (user-configured) tools --------------------------------
  # Same pattern: a master tile that collapses/expands its custom-tool switches.
  if configured_tools:
    custom_switches: list = []
    for tool in configured_tools:
      uuid = tool.get("id", "")
      label = tool.get("alias") or tool.get("tool_type", "tool")
      custom_switches.append(
        ft.Switch(
          height=30,
          disabled=not configured_master,
          value=configured.get(uuid, True),
          label=ft.Text(label, size=20, expand=True),
          on_change=lambda e, u=uuid: toggle_configured(u, e.control.value),
        )
      )
    rows.append(
      ft.ExpansionTile(
        title=ft.Column(
          [
            ft.Switch(
              height=30,
              value=configured_master,
              label="Custom Tools",
              label_text_style=ft.TextStyle(size=20),
              on_change=lambda e: toggle_configured_master(e.control.value),
            )
          ]
        ),
        expand=True,
        expanded=False,
        controls=[
          ft.Container(
            ft.Column(custom_switches, spacing=0),
            padding=ft.padding.only(left=30),
          )
        ],
      )
    )

  return ft.Column(
    [
      ft.Container(
        height=25,
        content=ft.Text(
          "Tools",
          size=15,
          color=ft.Colors.PRIMARY
        )
      ),
      ft.Container(
        ft.Column(
          rows,
          spacing=0
        ),
        # scroll=ft.ScrollMode.ADAPTIVE
        border_radius=3,
        border=ft.border.all(1, ft.Colors.PRIMARY),
      )
    ],
    spacing=0
  )


@ft.component
def SkillToggleList(skills=None, config=None, on_change=None, sync_key=None):
  """
  Flat skill toggle list.

  Args:
    skills:    list of skill dicts (id/alias/source/status).
    config:    current skills_config dict {skill_uuid: bool} used to seed state.
    on_change: callable(config) invoked after every toggle.
    sync_key:  identity of the config source; resyncs state when it changes.
  """
  skills = skills or []

  cfg, set_cfg = ft.use_state(config if config is not None else {})
  synced_key, set_synced_key = ft.use_state(_UNSET)

  if sync_key != synced_key:
    cfg = config if config is not None else {}
    set_cfg(cfg)
    set_synced_key(sync_key)

  def toggle(uuid, value):
    new = copy.deepcopy(cfg)
    new[uuid] = value
    set_cfg(new)
    if on_change:
      on_change(new)

  # Build the individual skill switches (or an empty-state message).
  if skills:
    skill_switches: list = []
    for skill in skills:
      uuid = skill.get("id", "")
      label = skill.get("alias") or skill.get("source", "skill")
      skill_switches.append(
        ft.Switch(
          height=30,
          value=cfg.get(uuid, True),
          label=ft.Text(label, size=20, expand=True),
          on_change=lambda e, u=uuid: toggle(u, e.control.value),
        )
      )
    body = ft.Container(
      ft.Column(skill_switches, spacing=0),
      padding=ft.padding.only(left=30),
    )
  else:
    body = ft.Container(
      ft.Text("No skills installed.", size=13, color=ft.Colors.GREY),
      padding=ft.padding.only(left=30),
    )

  # Collapsible tile so the whole skills section can expand/collapse, mirroring
  # the built-in / custom tool tiles.
  skills_tile = ft.ExpansionTile(
    title=ft.Column(
      [
        ft.Text("Installed Skills", size=20),
      ]
    ),
    expand=True,
    expanded=False,
    controls=[body],
  )

  return ft.Column(
    [
      ft.Container(
        height=25,
        content=ft.Text("Skills", size=15, color=ft.Colors.PRIMARY),
      ),
      ft.Container(
        ft.Column([skills_tile], spacing=0),
        border_radius=3,
        border=ft.border.all(1, ft.Colors.PRIMARY),
      ),
    ],
    spacing=0,
    scroll=ft.ScrollMode.ADAPTIVE,
  )
