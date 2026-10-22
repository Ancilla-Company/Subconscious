import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

/// Human readable form of a tool or group slug (`web_search` -> `Web Search`).
String toolDisplayName(String value) => value
    .split(RegExp('[_\\-\\s]+'))
    .where((String part) => part.isNotEmpty)
    .map(
      (String part) =>
          '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
    )
    .join(' ');

/// The tool allow-list editor shared by the workspace editor and the thread
/// settings panel: a "Builtin Tools" card (groups of engine tools) and a
/// "Custom Tools" card (configured tools by registry ID), each with a master
/// switch and an expandable list.
///
/// It owns only the expansion state; the policy itself lives in the caller,
/// which passes the current values and receives changes. When [editable] is
/// false every switch is disabled.
final class ToolPolicyList extends StatefulWidget {
  const ToolPolicyList({
    required this.catalog,
    required this.editable,
    required this.builtinEnabled,
    required this.configuredEnabled,
    required this.builtinGroups,
    required this.builtinTools,
    required this.configuredTools,
    required this.onBuiltinEnabled,
    required this.onConfiguredEnabled,
    required this.onGroupChanged,
    required this.onBuiltinToolChanged,
    required this.onConfiguredToolChanged,
    this.builtinInitiallyExpanded = true,
    this.configuredInitiallyExpanded = false,
    super.key,
  });

  /// The engine's tool catalog; null while it is loading.
  final ToolCatalog? catalog;
  final bool editable;
  final bool builtinEnabled;
  final bool configuredEnabled;

  /// Group slug -> group enabled.
  final Map<String, bool> builtinGroups;

  /// Group slug -> tool name -> enabled.
  final Map<String, Map<String, bool>> builtinTools;

  /// Registry uuid -> enabled.
  final Map<String, bool> configuredTools;
  final ValueChanged<bool> onBuiltinEnabled;
  final ValueChanged<bool> onConfiguredEnabled;
  final void Function(String group, bool enabled) onGroupChanged;
  final void Function(String group, String tool, bool enabled)
  onBuiltinToolChanged;
  final void Function(String uuid, bool enabled) onConfiguredToolChanged;
  final bool builtinInitiallyExpanded;
  final bool configuredInitiallyExpanded;

  @override
  State<ToolPolicyList> createState() => _ToolPolicyListState();
}

final class _ToolPolicyListState extends State<ToolPolicyList> {
  final Set<String> _openGroups = <String>{};

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _buildBuiltin(context),
      const SizedBox(height: 10),
      _buildConfigured(context),
    ],
  );

  Widget _buildBuiltin(BuildContext context) {
    final Map<String, List<BuiltinToolCatalogEntry>> groups =
        widget.catalog?.builtin ??
        const <String, List<BuiltinToolCatalogEntry>>{};
    return AppSectionCard(
      title: 'Builtin Tools',
      subtitle: 'Enable tools provided by the engine.',
      margin: EdgeInsets.zero,
      expandable: true,
      initiallyExpanded: widget.builtinInitiallyExpanded,
      padding: const EdgeInsets.all(12),
      trailing: AppSwitch(
        value: widget.builtinEnabled,
        onChanged: widget.editable ? widget.onBuiltinEnabled : null,
        semanticLabel: 'Enable built-in tools',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (groups.isEmpty)
            const _EmptyNote('No built-in tools are available.'),
          for (final MapEntry<String, List<BuiltinToolCatalogEntry>> group
              in groups.entries)
            _buildGroup(group.key, group.value),
        ],
      ),
    );
  }

  Widget _buildGroup(String group, List<BuiltinToolCatalogEntry> tools) {
    final bool open = _openGroups.contains(group);
    final String name = toolDisplayName(group);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppListRow(
          title: name,
          minHeight: 48,
          trailingInteractive: true,
          leading: Icon(
            open
                ? FluentIcons.chevron_down_20_regular
                : FluentIcons.chevron_right_20_regular,
          ),
          trailing: AppSwitch(
            value: widget.builtinGroups[group] ?? true,
            onChanged: widget.editable && widget.builtinEnabled
                ? (bool value) => widget.onGroupChanged(group, value)
                : null,
            semanticLabel: 'Enable $name tools',
          ),
          onTap: () => setState(() {
            if (!_openGroups.add(group)) _openGroups.remove(group);
          }),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final BuiltinToolCatalogEntry tool in tools)
                  _buildBuiltinTool(group, tool),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildBuiltinTool(String group, BuiltinToolCatalogEntry tool) {
    final bool value = widget.builtinTools[group]?[tool.name] ?? true;
    final bool enabled =
        widget.editable &&
        widget.builtinEnabled &&
        (widget.builtinGroups[group] ?? true);
    final String label = toolDisplayName(tool.name);
    void toggle(bool next) =>
        widget.onBuiltinToolChanged(group, tool.name, next);
    return AppListRow(
      title: label,
      subtitle: tool.doc.isEmpty ? null : tool.doc,
      minHeight: 48,
      trailingInteractive: true,
      onTap: enabled ? () => toggle(!value) : null,
      trailing: AppSwitch(
        value: value,
        onChanged: enabled ? toggle : null,
        semanticLabel: 'Enable $label',
      ),
    );
  }

  Widget _buildConfigured(BuildContext context) {
    final List<ToolRegistryEntry> tools =
        widget.catalog?.configured ?? const <ToolRegistryEntry>[];
    return AppSectionCard(
      title: 'Custom Tools',
      subtitle: 'Configured tools are addressed by their stable registry ID.',
      margin: EdgeInsets.zero,
      expandable: true,
      initiallyExpanded: widget.configuredInitiallyExpanded,
      trailing: AppSwitch(
        value: widget.configuredEnabled,
        onChanged: widget.editable ? widget.onConfiguredEnabled : null,
        semanticLabel: 'Enable custom tools',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (tools.isEmpty)
            const _EmptyNote('No custom tools are configured.'),
          for (final ToolRegistryEntry tool in tools)
            _buildConfiguredTool(tool),
        ],
      ),
    );
  }

  Widget _buildConfiguredTool(ToolRegistryEntry tool) {
    final bool value = widget.configuredTools[tool.uuid] ?? true;
    final bool enabled = widget.editable && widget.configuredEnabled;
    final String label = tool.alias?.trim().isNotEmpty ?? false
        ? tool.alias!
        : tool.name;
    void toggle(bool next) => widget.onConfiguredToolChanged(tool.uuid, next);
    return AppListRow(
      title: label,
      subtitle: tool.uuid,
      minHeight: 48,
      trailingInteractive: true,
      onTap: enabled ? () => toggle(!value) : null,
      trailing: AppSwitch(
        value: value,
        onChanged: enabled ? toggle : null,
        semanticLabel: 'Enable $label',
      ),
    );
  }
}

final class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      message,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}
