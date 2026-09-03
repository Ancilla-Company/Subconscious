import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../context/presentation/context_panel.dart';
import '../../settings/controller/settings_controller.dart';
import '../../settings/presentation/settings_main_panel.dart';
import '../controller/dashboard_controller.dart';

final class DashboardMainPanel extends StatelessWidget {
  const DashboardMainPanel({required this.controller, super.key});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[controller, controller.settings]),
    builder: (BuildContext context, Widget? child) {
      final Workspace? workspace = controller.selectedWorkspace;
      final MainPanelDestination destination = controller.settings.destination;
      final Widget panel = switch (destination) {
        MainPanelDestination.workspace => Theme(
          data: _workspaceFormTheme(context),
          child: controller.isCreatingWorkspace
              ? _WorkspaceCreatePanel(controller: controller)
              : workspace == null
              ? const _WorkspaceUnavailablePanel()
              : _WorkspaceDetailsPanel(
                  key: ValueKey<String>(workspace.uuid),
                  controller: controller,
                  workspace: workspace,
                ),
        ),
        MainPanelDestination.files => WorkspaceFileEditor(
          controller: controller,
        ),
        MainPanelDestination.settings => SettingsMainPanel(
          controller: controller.settings,
          dashboardController: controller,
        ),
        MainPanelDestination.utility => const _UtilityPanel(),
      };
      return ClipRect(
        child: RepaintBoundary(
          key: ValueKey<MainPanelDestination>(destination),
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: SizedBox.expand(child: panel),
          ),
        ),
      );
    },
  );
}

ThemeData _workspaceFormTheme(BuildContext context) {
  final ThemeData base = settingsFormTheme(context);
  final ColorScheme colors = base.colorScheme;
  return base.copyWith(
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      border: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(
          color: colors.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      hintStyle: TextStyle(
        color: colors.onSurfaceVariant.withValues(alpha: 0.33),
      ),
    ),
  );
}

IconButton _dashboardIconButton({
  required String tooltip,
  required VoidCallback? onPressed,
  required Widget icon,
  Color? foregroundColor,
}) => IconButton(
  tooltip: tooltip,
  constraints: const BoxConstraints.tightFor(width: 32, height: 32),
  padding: EdgeInsets.zero,
  style: IconButton.styleFrom(
    foregroundColor: foregroundColor,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
  ),
  onPressed: onPressed,
  icon: icon,
);

final class _WorkspaceDetailsPanel extends StatefulWidget {
  const _WorkspaceDetailsPanel({
    required this.controller,
    required this.workspace,
    super.key,
  });

  final DashboardController controller;
  final Workspace workspace;

  @override
  State<_WorkspaceDetailsPanel> createState() => _WorkspaceDetailsPanelState();
}

final class _WorkspaceDetailsPanelState extends State<_WorkspaceDetailsPanel> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _pathController;
  List<ModelInfo> _models = const <ModelInfo>[];
  ToolCatalog? _toolCatalog;
  List<String> _paths = <String>[];
  Map<String, dynamic> _rawApproval = <String, dynamic>{};
  Map<String, dynamic> _rawRag = <String, dynamic>{};
  Map<String, dynamic> _rawTools = <String, dynamic>{};
  Map<String, bool> _builtinGroups = <String, bool>{};
  Map<String, Map<String, bool>> _builtinTools = <String, Map<String, bool>>{};
  Map<String, bool> _configuredTools = <String, bool>{};
  String? _selectedModelId;
  late String _savedSignature;
  bool _buildKnowledgeGraph = false;
  bool _approveQueries = true;
  bool _approveMutations = true;
  bool _builtinEnabled = true;
  bool _configuredEnabled = true;
  bool _builtinExpanded = false;
  bool _configuredExpanded = false;
  bool _isSynchronizing = false;
  bool _isLoadingOptions = true;
  bool _isSaving = false;
  bool _isDeleting = false;
  Object? _error;

  bool get _isBusy => _isSaving || _isDeleting;
  String get _name => _nameController.text.trim();
  String get _description => _descriptionController.text.trim();
  bool get _isDirty => _signature() != _savedSignature;
  bool get _canSave =>
      widget.controller.isConnected &&
      !_isBusy &&
      !_isLoadingOptions &&
      _name.isNotEmpty &&
      _isDirty;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _descriptionController = TextEditingController();
    _pathController = TextEditingController();
    _synchronizeWorkspace(widget.workspace);
    _nameController.addListener(_onFieldChanged);
    _descriptionController.addListener(_onFieldChanged);
    unawaited(_loadOptions());
  }

  @override
  void didUpdateWidget(covariant _WorkspaceDetailsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace) {
      _synchronizeWorkspace(widget.workspace);
    }
  }

  void _synchronizeWorkspace(Workspace workspace) {
    _isSynchronizing = true;
    _nameController.text = workspace.name;
    _descriptionController.text = workspace.description ?? '';
    _selectedModelId = workspace.defaultModelId;
    _paths = _readDirectories(workspace.directories);
    _rawApproval = _decodeObject(workspace.approvalConfig);
    _rawRag = _decodeObject(workspace.ragConfig);
    _rawTools = _decodeObject(workspace.toolsConfig);
    _buildKnowledgeGraph = _readBool(
      _rawRag,
      'semantic_graph',
      fallback: false,
    );
    _approveQueries = _readBool(_rawApproval, 'query', fallback: true);
    _approveMutations = _readBool(_rawApproval, 'mutation', fallback: true);
    _builtinEnabled = _readBool(_rawTools, 'builtin_enabled', fallback: true);
    _configuredEnabled = _readBool(
      _rawTools,
      'configured_enabled',
      fallback: true,
    );
    if (_toolCatalog case final ToolCatalog catalog) {
      _populateToolPolicy(catalog);
    }
    _savedSignature = _signature();
    _error = null;
    _isSynchronizing = false;
  }

  Future<void> _loadOptions() async {
    final EngineRepository? repository = widget.controller.repository;
    if (repository == null) {
      if (mounted) {
        setState(() {
          _isLoadingOptions = false;
          _error = StateError('The Subconscious engine is not connected.');
        });
      }
      return;
    }

    Object? loadError;
    List<ModelInfo> models = const <ModelInfo>[];
    ToolCatalog? catalog;
    try {
      models = await repository.listModels();
    } on Object catch (error) {
      loadError = error;
    }
    try {
      catalog = await repository.rest.listToolCatalog();
    } on Object catch (error) {
      loadError ??= error;
    }
    if (!mounted) return;
    final bool wasDirty = _isDirty;
    setState(() {
      _models = models;
      _toolCatalog = catalog;
      if (catalog != null) _populateToolPolicy(catalog);
      _isLoadingOptions = false;
      _error = loadError;
      if (!wasDirty) _savedSignature = _signature();
    });
  }

  void _populateToolPolicy(ToolCatalog catalog) {
    final Map<String, dynamic> builtin = _objectValue(_rawTools['builtin']);
    _builtinGroups = <String, bool>{};
    _builtinTools = <String, Map<String, bool>>{};
    for (final MapEntry<String, List<BuiltinToolCatalogEntry>> group
        in catalog.builtin.entries) {
      final Map<String, dynamic> groupConfig = _objectValue(builtin[group.key]);
      final Map<String, dynamic> tools = _objectValue(groupConfig['tools']);
      _builtinGroups[group.key] = _readBool(
        groupConfig,
        'enabled',
        fallback: true,
      );
      _builtinTools[group.key] = <String, bool>{
        for (final BuiltinToolCatalogEntry tool in group.value)
          tool.name: _readBool(tools, tool.name, fallback: true),
      };
    }
    final Map<String, dynamic> configured = _objectValue(
      _rawTools['configured'],
    );
    _configuredTools = <String, bool>{
      for (final ToolRegistryEntry tool in catalog.configured)
        tool.uuid: _readBool(configured, tool.uuid, fallback: true),
    };
  }

  void _onFieldChanged() {
    if (!_isSynchronizing && mounted) setState(() => _error = null);
  }

  void _change(VoidCallback update) {
    setState(() {
      update();
      _error = null;
    });
  }

  void _addPath() {
    final String raw = _pathController.text.trim();
    final String? path = _normalizeAbsolutePath(raw);
    if (path == null) {
      setState(
        () => _error = raw.isEmpty
            ? 'Enter an absolute folder path before adding it.'
            : 'Workspace paths must be fully-qualified absolute paths: $raw',
      );
      return;
    }
    if (_paths.any(
      (String existing) => existing.toLowerCase() == path.toLowerCase(),
    )) {
      setState(() => _error = 'That workspace path is already allowed.');
      return;
    }
    _change(() {
      _paths = <String>[..._paths, path];
      _pathController.clear();
    });
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.controller.updateWorkspace(
        widget.workspace,
        name: _name,
        description: _description.isEmpty ? null : _description,
        defaultModelId: _selectedModelId,
        directories: jsonEncode(_paths),
        approvalConfig: _serializeApproval(),
        ragConfig: _serializeRag(),
        toolsConfig: _serializeTools(),
      );
      if (!mounted) return;
      _synchronizeWorkspace(
        widget.controller.selectedWorkspace ?? widget.workspace,
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String _serializeApproval() {
    final Map<String, dynamic> value = _deepCopy(_rawApproval)
      ..['query'] = _approveQueries
      ..['mutation'] = _approveMutations;
    return jsonEncode(value);
  }

  String _serializeRag() {
    final Map<String, dynamic> value = _deepCopy(_rawRag)
      ..['semantic_graph'] = _buildKnowledgeGraph;
    return jsonEncode(value);
  }

  String _serializeTools() {
    final Map<String, dynamic> value = _deepCopy(_rawTools)
      ..['builtin_enabled'] = _builtinEnabled
      ..['configured_enabled'] = _configuredEnabled;
    final Map<String, dynamic> builtin = _objectValue(value['builtin']);
    for (final String slug in _builtinGroups.keys) {
      final Map<String, dynamic> group = _objectValue(builtin[slug])
        ..['enabled'] = _builtinGroups[slug];
      final Map<String, dynamic> tools = _objectValue(group['tools']);
      for (final MapEntry<String, bool> tool
          in (_builtinTools[slug] ?? const <String, bool>{}).entries) {
        tools[tool.key] = tool.value;
      }
      group['tools'] = tools;
      builtin[slug] = group;
    }
    value['builtin'] = builtin;
    final Map<String, dynamic> configured = _objectValue(value['configured']);
    for (final MapEntry<String, bool> tool in _configuredTools.entries) {
      configured[tool.key] = tool.value;
    }
    value['configured'] = configured;
    return jsonEncode(value);
  }

  Future<void> _confirmDelete() async {
    if (_isBusy || !widget.controller.isConnected) return;
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Delete workspace?'),
            content: Text(
              'Delete “${widget.workspace.name}”? This also deletes its threads and cannot be undone.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() {
      _isDeleting = true;
      _error = null;
    });
    try {
      await widget.controller.deleteWorkspace(widget.workspace);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _isDeleting = false;
          _error = error;
        });
      }
    }
  }

  String _signature() => jsonEncode(<String, dynamic>{
    'name': _name,
    'description': _description,
    'model': _selectedModelId,
    'paths': _paths,
    'graph': _buildKnowledgeGraph,
    'queries': _approveQueries,
    'mutations': _approveMutations,
    'builtinEnabled': _builtinEnabled,
    'configuredEnabled': _configuredEnabled,
    'builtinGroups': _builtinGroups,
    'builtinTools': _builtinTools,
    'configuredTools': _configuredTools,
  });

  @override
  void dispose() {
    _nameController
      ..removeListener(_onFieldChanged)
      ..dispose();
    _descriptionController
      ..removeListener(_onFieldChanged)
      ..dispose();
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHeader(context, colors),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 750),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _label(context, 'Name'),
                      TextField(
                        controller: _nameController,
                        enabled: !_isBusy,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          hintText: 'Workspace name',
                        ),
                      ),
                      const SizedBox(height: 16),
                      _label(context, 'Description'),
                      TextField(
                        controller: _descriptionController,
                        enabled: !_isBusy,
                        minLines: 4,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          hintText: 'Optional description',
                        ),
                      ),
                      const SizedBox(height: 16),
                      _label(context, 'Default model'),
                      _buildModelPicker(),
                      const SizedBox(height: 18),
                      _buildPathEditor(context, colors),
                      const SizedBox(height: 18),
                      _switchRow(
                        context,
                        title: 'Build knowledge graph',
                        subtitle: 'Enable semantic_graph for this workspace.',
                        value: _buildKnowledgeGraph,
                        onChanged: (bool value) =>
                            _change(() => _buildKnowledgeGraph = value),
                      ),
                      const SizedBox(height: 18),
                      _label(context, 'Require approval'),
                      _switchRow(
                        context,
                        title: 'Queries',
                        value: _approveQueries,
                        onChanged: (bool value) =>
                            _change(() => _approveQueries = value),
                      ),
                      _switchRow(
                        context,
                        title: 'Mutations',
                        value: _approveMutations,
                        onChanged: (bool value) =>
                            _change(() => _approveMutations = value),
                      ),
                      const SizedBox(height: 18),
                      _label(context, 'Tool allow list'),
                      Text(
                        'Choose the built-in tool groups and individual functions this workspace may offer to agents. Thread policies may further restrict or override this default.',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 10),
                      if (_isLoadingOptions)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      _buildBuiltinTools(context),
                      const SizedBox(height: 10),
                      _buildConfiguredTools(context),
                      const SizedBox(height: 20),
                      _buildMetadata(context),
                      if (_error case final Object error) ...<Widget>[
                        const SizedBox(height: 16),
                        Text(
                          'Workspace operation failed: $error',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.error),
                        ),
                      ],
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme colors) => SizedBox(
    height: 56,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 750),
          child: Row(
            children: <Widget>[
              Text(
                'Edit workspace',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              _dashboardIconButton(
                tooltip: 'Delete workspace',
                onPressed: _isBusy || !widget.controller.isConnected
                    ? null
                    : _confirmDelete,
                foregroundColor: colors.error,
                icon: _isDeleting
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(FluentIcons.delete_20_regular, size: 18),
              ),
              const SizedBox(width: 4),
              _dashboardIconButton(
                tooltip: 'Save workspace',
                onPressed: _canSave ? _save : null,
                icon: _isSaving
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(FluentIcons.save_20_regular, size: 18),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildModelPicker() {
    final String value = _selectedModelId ?? '';
    final bool known = _models.any((ModelInfo model) => model.id == value);
    return DropdownButtonFormField<String>(
      key: ValueKey<String>('model:$value'),
      initialValue: value,
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(fontWeight: FontWeight.normal),
      decoration: const InputDecoration(),
      items: <DropdownMenuItem<String>>[
        const DropdownMenuItem<String>(value: '', child: Text('Default model')),
        if (value.isNotEmpty && !known)
          DropdownMenuItem<String>(value: value, child: Text(value)),
        for (final ModelInfo model in _models)
          DropdownMenuItem<String>(value: model.id, child: Text(model.name)),
      ],
      onChanged: _isBusy
          ? null
          : (String? selected) => _change(
              () => _selectedModelId = selected?.isEmpty ?? true
                  ? null
                  : selected,
            ),
    );
  }

  Widget _buildPathEditor(BuildContext context, ColorScheme colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _label(context, 'Workspace path allow list'),
      Text(
        'Only listed absolute folders may be granted to filesystem, image, download, and terminal tools for this workspace.',
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: colors.onSurfaceVariant),
      ),
      const SizedBox(height: 8),
      Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _pathController,
              enabled: !_isBusy,
              decoration: const InputDecoration(
                hintText: r'C:\Projects\example',
              ),
              onSubmitted: (_) => _addPath(),
            ),
          ),
          const SizedBox(width: 8),
          _dashboardIconButton(
            tooltip: 'Add workspace path',
            onPressed: _isBusy ? null : _addPath,
            icon: const Icon(FluentIcons.add_20_regular, size: 18),
          ),
        ],
      ),
      if (_paths.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'No workspace paths have been allowed yet. Local file-oriented tools will have no workspace scope.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        )
      else
        for (final String path in _paths)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(path, overflow: TextOverflow.ellipsis),
            trailing: _dashboardIconButton(
              tooltip: 'Remove workspace path: $path',
              onPressed: _isBusy
                  ? null
                  : () => _change(
                      () => _paths = _paths
                          .where((String item) => item != path)
                          .toList(growable: false),
                    ),
              icon: const Icon(FluentIcons.dismiss_20_regular, size: 18),
            ),
          ),
    ],
  );

  Widget _switchRow(
    BuildContext context, {
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title),
              if (subtitle != null)
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        _RectangularSwitch(
          value: value,
          onChanged: _isBusy ? null : onChanged,
          semanticLabel: title,
        ),
      ],
    ),
  );

  Widget _buildBuiltinTools(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(6)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ListTile(
          onTap: () => setState(() => _builtinExpanded = !_builtinExpanded),
          title: const Text('Builtin Tools'),
          subtitle: const Text('Enable tools provided by the engine.'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _RectangularSwitch(
                value: _builtinEnabled,
                onChanged: _isBusy
                    ? null
                    : (bool value) => _change(() => _builtinEnabled = value),
                semanticLabel: 'Enable built-in tools',
              ),
              const SizedBox(width: 8),
              Icon(
                _builtinExpanded
                    ? FluentIcons.chevron_up_20_regular
                    : FluentIcons.chevron_down_20_regular,
                size: 17,
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: !_builtinExpanded
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Divider(height: 1),
                    if (_toolCatalog?.builtin.isEmpty ?? true)
                      const ListTile(
                        title: Text('No built-in tools are available.'),
                      ),
                    for (final MapEntry<String, List<BuiltinToolCatalogEntry>>
                        group
                        in _toolCatalog?.builtin.entries ??
                            const <String, List<BuiltinToolCatalogEntry>>{}
                                .entries)
                      ExpansionTile(
                        title: Text(_displayName(group.key)),
                        trailing: _RectangularSwitch(
                          value: _builtinGroups[group.key] ?? true,
                          onChanged: !_builtinEnabled || _isBusy
                              ? null
                              : (bool value) => _change(
                                  () => _builtinGroups[group.key] = value,
                                ),
                          semanticLabel:
                              'Enable ${_displayName(group.key)} tools',
                        ),
                        children: <Widget>[
                          for (final BuiltinToolCatalogEntry tool
                              in group.value)
                            _buildBuiltinToolRow(context, group.key, tool),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    ),
  );

  Widget _buildBuiltinToolRow(
    BuildContext context,
    String group,
    BuiltinToolCatalogEntry tool,
  ) {
    final bool value = _builtinTools[group]?[tool.name] ?? true;
    final bool enabled =
        _builtinEnabled && (_builtinGroups[group] ?? true) && !_isBusy;
    final String label = _displayName(tool.name);
    void toggle(bool next) =>
        _change(() => _builtinTools[group]![tool.name] = next);
    return ListTile(
      title: Text(label),
      subtitle: tool.doc.isEmpty ? null : Text(tool.doc),
      onTap: enabled ? () => toggle(!value) : null,
      trailing: _RectangularSwitch(
        value: value,
        onChanged: enabled ? toggle : null,
        semanticLabel: 'Enable $label',
      ),
    );
  }

  Widget _buildConfiguredTools(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(6)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ListTile(
          onTap: () =>
              setState(() => _configuredExpanded = !_configuredExpanded),
          title: const Text('Custom Tools'),
          subtitle: const Text(
            'Configured tools are addressed by their stable registry ID.',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _RectangularSwitch(
                value: _configuredEnabled,
                onChanged: _isBusy
                    ? null
                    : (bool value) => _change(() => _configuredEnabled = value),
                semanticLabel: 'Enable custom tools',
              ),
              const SizedBox(width: 8),
              Icon(
                _configuredExpanded
                    ? FluentIcons.chevron_up_20_regular
                    : FluentIcons.chevron_down_20_regular,
                size: 17,
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: !_configuredExpanded
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Divider(height: 1),
                    if (_toolCatalog?.configured.isEmpty ?? true)
                      const ListTile(
                        title: Text('No custom tools are configured.'),
                      ),
                    for (final ToolRegistryEntry tool
                        in _toolCatalog?.configured ??
                            const <ToolRegistryEntry>[])
                      _buildConfiguredToolRow(tool),
                  ],
                ),
        ),
      ],
    ),
  );

  Widget _buildConfiguredToolRow(ToolRegistryEntry tool) {
    final bool value = _configuredTools[tool.uuid] ?? true;
    final bool enabled = _configuredEnabled && !_isBusy;
    final String label = tool.alias?.trim().isNotEmpty ?? false
        ? tool.alias!
        : tool.name;
    void toggle(bool next) => _change(() => _configuredTools[tool.uuid] = next);
    return ListTile(
      title: Text(label),
      subtitle: Text(tool.uuid),
      onTap: enabled ? () => toggle(!value) : null,
      trailing: _RectangularSwitch(
        value: value,
        onChanged: enabled ? toggle : null,
        semanticLabel: 'Enable $label',
      ),
    );
  }

  Widget _buildMetadata(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _label(context, 'UUID'),
      SelectableText(widget.workspace.uuid),
      const SizedBox(height: 16),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _label(context, 'Created'),
                Text(_formatDate(widget.workspace.createdAt)),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _label(context, 'Updated'),
                Text(_formatDate(widget.workspace.updatedAt)),
              ],
            ),
          ),
        ],
      ),
    ],
  );

  static Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );

  static Map<String, dynamic> _decodeObject(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final Object? value = jsonDecode(raw);
      return _objectValue(value);
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  static Map<String, dynamic> _objectValue(Object? value) => value is Map
      ? value.map((Object? key, Object? item) => MapEntry('$key', item))
      : <String, dynamic>{};

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> value) =>
      _objectValue(jsonDecode(jsonEncode(value)));

  static bool _readBool(
    Map<String, dynamic> value,
    String key, {
    required bool fallback,
  }) => value[key] is bool ? value[key] as bool : fallback;

  static List<String> _readDirectories(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String>[];
    try {
      final Object? value = jsonDecode(raw);
      if (value is! List) return <String>[];
      return value.whereType<String>().toList(growable: false);
    } on FormatException {
      return <String>[];
    }
  }

  static String? _normalizeAbsolutePath(String raw) {
    final String value = raw.trim();
    final bool isWindowsDrive = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
    final bool isUnc = value.startsWith(r'\\');
    final bool isPosix = value.startsWith('/');
    if (value.isEmpty || (!isWindowsDrive && !isUnc && !isPosix)) return null;
    String normalized = value;
    while (normalized.length > 1 &&
        (normalized.endsWith('\\') || normalized.endsWith('/')) &&
        !RegExp(r'^[A-Za-z]:[\\/]$').hasMatch(normalized)) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static String _displayName(String value) => value
      .split(RegExp('[_\\-\\s]+'))
      .where((String part) => part.isNotEmpty)
      .map(
        (String part) =>
            '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
      )
      .join(' ');

  static String _formatDate(DateTime? value) {
    if (value == null) return '—';
    final DateTime local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

final class _WorkspaceCreatePanel extends StatefulWidget {
  const _WorkspaceCreatePanel({required this.controller});

  final DashboardController controller;

  @override
  State<_WorkspaceCreatePanel> createState() => _WorkspaceCreatePanelState();
}

final class _WorkspaceCreatePanelState extends State<_WorkspaceCreatePanel> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  bool _isCreating = false;
  Object? _error;

  String get _name => _nameController.text.trim();
  String get _description => _descriptionController.text.trim();
  bool get _canCreate =>
      widget.controller.isConnected && !_isCreating && _name.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_onNameChanged);
  }

  void _onNameChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _create() async {
    if (!_canCreate) return;
    setState(() {
      _isCreating = true;
      _error = null;
    });
    try {
      await widget.controller.createWorkspace(
        name: _name,
        description: _description.isEmpty ? null : _description,
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  static Widget _fieldLabel(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );

  @override
  void dispose() {
    _nameController
      ..removeListener(_onNameChanged)
      ..dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.center,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 750),
                  child: Row(
                    children: <Widget>[
                      Text(
                        'New workspace',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const Spacer(),
                      _dashboardIconButton(
                        tooltip: 'Cancel workspace creation',
                        onPressed: _isCreating
                            ? null
                            : widget.controller.cancelWorkspaceCreation,
                        icon: const Icon(
                          FluentIcons.dismiss_20_regular,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 4),
                      _dashboardIconButton(
                        tooltip: 'Create workspace',
                        onPressed: _canCreate ? _create : null,
                        icon: _isCreating
                            ? const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(FluentIcons.add_20_regular, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 750),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _fieldLabel(context, 'Name'),
                      TextField(
                        controller: _nameController,
                        autofocus: true,
                        enabled: !_isCreating,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _create(),
                        decoration: const InputDecoration(
                          hintText: 'Workspace name',
                        ),
                      ),
                      const SizedBox(height: 16),
                      _fieldLabel(context, 'Description'),
                      TextField(
                        controller: _descriptionController,
                        enabled: !_isCreating,
                        minLines: 4,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          hintText: 'Optional description',
                        ),
                      ),
                      if (_error case final Object error) ...<Widget>[
                        const SizedBox(height: 16),
                        Text(
                          "Couldn't create workspace: $error",
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _WorkspaceUnavailablePanel extends StatelessWidget {
  const _WorkspaceUnavailablePanel();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: const Center(child: Text('Select a workspace to view its details.')),
  );
}

final class _UtilityPanel extends StatelessWidget {
  const _UtilityPanel();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('Utility panel', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Preview · Terminal — coming soon',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

final class _RectangularSwitch extends StatelessWidget {
  const _RectangularSwitch({
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool enabled = onChanged != null;
    final Color trackColor = enabled
        ? (value ? colors.primary : colors.surfaceContainerHighest)
        : (value
              ? colors.primary.withValues(alpha: 0.38)
              : colors.onSurface.withValues(alpha: 0.12));
    final Color thumbColor = enabled
        ? (value ? colors.onPrimary : colors.onSurfaceVariant)
        : colors.onSurface.withValues(alpha: 0.38);

    void toggle() => onChanged?.call(!value);

    return Semantics(
      label: semanticLabel,
      button: true,
      enabled: enabled,
      toggled: value,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? toggle : null,
          child: SizedBox.square(
            dimension: 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 40,
                height: 24,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: trackColor,
                  borderRadius: const BorderRadius.all(Radius.circular(3)),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 150),
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: thumbColor,
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
