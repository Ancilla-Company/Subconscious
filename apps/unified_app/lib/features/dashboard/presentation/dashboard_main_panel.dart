import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../../account/account_controller.dart';
import '../../agents/presentation/agent_panel.dart';
import '../../editor/presentation/workspace_file_editor.dart';
import '../../settings/controller/settings_controller.dart';
import '../../settings/presentation/settings_main_panel.dart';
import '../../tools/presentation/tool_policy_list.dart';
import '../controller/dashboard_controller.dart';

final class DashboardMainPanel extends StatelessWidget {
  const DashboardMainPanel({
    required this.controller,
    required this.accountController,
    super.key,
  });

  final DashboardController controller;
  final AccountController accountController;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[controller, controller.settings]),
    builder: (BuildContext context, Widget? child) {
      final Workspace? workspace = controller.selectedWorkspace;
      final MainPanelDestination destination = controller.settings.destination;
      final Widget panel = switch (destination) {
        MainPanelDestination.workspace => AppFormTheme(
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
        MainPanelDestination.agent => AppFormTheme(
          child: AgentMainPanel(controller: controller),
        ),
        MainPanelDestination.files => WorkspaceFileEditor(
          controller: controller,
        ),
        MainPanelDestination.settings => SettingsMainPanel(
          controller: controller.settings,
          dashboardController: controller,
          accountController: accountController,
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

Widget _workspaceModelLabel(String name) =>
    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis);

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
  bool _approveCreate = true;
  bool _approveRead = true;
  bool _approveUpdate = true;
  bool _approveDelete = true;
  bool _builtinEnabled = true;
  bool _configuredEnabled = true;
  bool _isSynchronizing = false;
  bool _isLoadingOptions = true;
  bool _isSaving = false;
  bool _isDeleting = false;
  final Set<int> _reindexingRootIndexes = <int>{};
  Object? _error;

  bool get _isBusy =>
      _isSaving || _isDeleting || _reindexingRootIndexes.isNotEmpty;
  String get _name => _nameController.text.trim();
  String get _description => _descriptionController.text.trim();
  bool get _isDirty => _signature() != _savedSignature;
  bool get _canSave =>
      widget.controller.isConnected &&
      !_isBusy &&
      !_isLoadingOptions &&
      _name.isNotEmpty &&
      _isDirty;
  bool get _canAddPath =>
      widget.controller.isConnected &&
      !_isBusy &&
      !_isLoadingOptions &&
      _name.isNotEmpty &&
      _pathController.text.trim().isNotEmpty;
  bool get _canPersistRag =>
      widget.controller.isConnected &&
      !_isBusy &&
      !_isLoadingOptions &&
      _name.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _descriptionController = TextEditingController();
    _pathController = TextEditingController();
    _synchronizeWorkspace(widget.workspace);
    _nameController.addListener(_onFieldChanged);
    _descriptionController.addListener(_onFieldChanged);
    _pathController.addListener(_onFieldChanged);
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
    final bool legacyQuery = _readBool(_rawApproval, 'query', fallback: true);
    final bool legacyMutation = _readBool(
      _rawApproval,
      'mutation',
      fallback: true,
    );
    _approveCreate = _readBool(
      _rawApproval,
      'create',
      fallback: legacyMutation,
    );
    _approveRead = _readBool(_rawApproval, 'read', fallback: legacyQuery);
    _approveUpdate = _readBool(
      _rawApproval,
      'update',
      fallback: legacyMutation,
    );
    _approveDelete = _readBool(
      _rawApproval,
      'delete',
      fallback: legacyMutation,
    );
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

  Future<void> _addPath() async {
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
      _setRagEnabled(path, true);
    });
    _pathController.clear();
    await _save();
  }

  void _removePath(String path) => _change(() {
    _paths = _paths
        .where((String item) => item != path)
        .toList(growable: false);
    _setRagEnabled(path, true);
  });

  Future<void> _toggleRag(String path, bool enabled) async {
    if (!_canPersistRag) return;
    _change(() => _setRagEnabled(path, enabled));
    await _save();
  }

  Future<void> _reindexRoot(int rootIndex, String path) async {
    if (_isBusy || !widget.controller.isConnected || !_isRagEnabled(path)) {
      return;
    }
    final RestEngineClient? client = widget.controller.repository?.rest;
    if (client == null) {
      setState(
        () => _error = StateError('The Subconscious engine is not connected.'),
      );
      return;
    }
    setState(() {
      _reindexingRootIndexes.add(rootIndex);
      _error = null;
    });
    try {
      await client
          .indexWorkspaceRagRoot(
            workspaceUuid: widget.workspace.uuid,
            rootIndex: rootIndex,
          )
          .timeout(DashboardController.requestTimeout);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() => _reindexingRootIndexes.remove(rootIndex));
      }
    }
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
        ragConfig: jsonEncode(_rawRag),
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
      ..remove('query')
      ..remove('mutation')
      ..['create'] = _approveCreate
      ..['read'] = _approveRead
      ..['update'] = _approveUpdate
      ..['delete'] = _approveDelete;
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
        await showAppDialog<bool>(
          context: context,
          builder: (BuildContext context) => AppDialog(
            title: 'Delete workspace?',
            content: Text(
              'Delete “${widget.workspace.name}”? This also deletes its threads and agents and cannot be undone.',
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
    'rag': _rawRag,
    'approveCreate': _approveCreate,
    'approveRead': _approveRead,
    'approveUpdate': _approveUpdate,
    'approveDelete': _approveDelete,
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
    _pathController
      ..removeListener(_onFieldChanged)
      ..dispose();
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
                      AppTextField(
                        label: 'Name',
                        controller: _nameController,
                        enabled: !_isBusy,
                        textInputAction: TextInputAction.next,
                        hintText: 'Workspace name',
                      ),
                      AppTextField(
                        label: 'Description',
                        controller: _descriptionController,
                        enabled: !_isBusy,
                        minLines: 4,
                        maxLines: 8,
                        hintText: 'Optional description',
                      ),
                      AppFieldLabel('Default model'),
                      _buildModelPicker(),
                      _buildPathEditor(context, colors),
                      AppFieldLabel('Require approval'),
                      _switchRow(
                        context,
                        title: 'Create',
                        value: _approveCreate,
                        onChanged: (bool value) =>
                            _change(() => _approveCreate = value),
                      ),
                      _switchRow(
                        context,
                        title: 'Read',
                        value: _approveRead,
                        onChanged: (bool value) =>
                            _change(() => _approveRead = value),
                      ),
                      _switchRow(
                        context,
                        title: 'Update',
                        value: _approveUpdate,
                        onChanged: (bool value) =>
                            _change(() => _approveUpdate = value),
                      ),
                      _switchRow(
                        context,
                        title: 'Delete',
                        value: _approveDelete,
                        onChanged: (bool value) =>
                            _change(() => _approveDelete = value),
                      ),
                      AppFieldLabel('Tool allow list'),
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
                      ToolPolicyList(
                        catalog: _toolCatalog,
                        editable: !_isBusy,
                        builtinInitiallyExpanded: false,
                        builtinEnabled: _builtinEnabled,
                        configuredEnabled: _configuredEnabled,
                        builtinGroups: _builtinGroups,
                        builtinTools: _builtinTools,
                        configuredTools: _configuredTools,
                        onBuiltinEnabled: (bool value) =>
                            _change(() => _builtinEnabled = value),
                        onConfiguredEnabled: (bool value) =>
                            _change(() => _configuredEnabled = value),
                        onGroupChanged: (String group, bool value) =>
                            _change(() => _builtinGroups[group] = value),
                        onBuiltinToolChanged: (
                          String group,
                          String tool,
                          bool value,
                        ) => _change(() => _builtinTools[group]![tool] = value),
                        onConfiguredToolChanged: (String uuid, bool value) =>
                            _change(() => _configuredTools[uuid] = value),
                      ),
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
              AppIconButton(
                outlined: true,
                tooltip: 'Delete workspace',
                onPressed: _isBusy || !widget.controller.isConnected
                    ? null
                    : _confirmDelete,
                destructive: true,
                busy: _isDeleting,
                icon: FluentIcons.delete_20_regular,
              ),
              AppSpacing.controlGap,
              AppIconButton(
                outlined: true,
                tooltip: 'Save workspace',
                onPressed: _canSave ? _save : null,
                busy: _isSaving,
                icon: FluentIcons.save_20_regular,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildModelPicker() {
    final String? value = _selectedModelId?.trim().isNotEmpty ?? false
        ? _selectedModelId
        : null;
    final bool known = _models.any((ModelInfo model) => model.id == value);
    final bool hasOptions = _models.isNotEmpty || value != null;
    return AppDropdownField<String>(
      key: ValueKey<String>('model:${value ?? ''}'),
      value: value,
      hint: Text(
        _models.isEmpty ? 'No models available' : 'Select a model',
        overflow: TextOverflow.ellipsis,
      ),
      items: <DropdownMenuItem<String>>[
        if (value != null && !known)
          DropdownMenuItem<String>(
            value: value,
            child: _workspaceModelLabel(value),
          ),
        for (final ModelInfo model in _models.where(
          (ModelInfo m) => m.isChatModel,
        ))
          DropdownMenuItem<String>(
            value: model.id,
            child: _workspaceModelLabel(model.name),
          ),
      ],
      onChanged: _isBusy || !hasOptions
          ? null
          : (String? selected) {
              if (selected != null) {
                _change(() => _selectedModelId = selected);
              }
            },
    );
  }

  Widget _buildPathEditor(BuildContext context, ColorScheme colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      AppFieldLabel('RAG & workspace folders'),
      Text(
        'These folders appear in the Files view and, when RAG is enabled, are indexed daily for semantic RAG so the model can choose to search their content. Sensitive files are represented by name only.',
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: colors.onSurfaceVariant),
      ),
      const SizedBox(height: 8),
      AppFieldRow(
        field: AppTextField(
          controller: _pathController,
          enabled: !_isBusy,
          hintText: r'C:\Projects\example',
          onSubmitted: (_) {
            if (_canAddPath) unawaited(_addPath());
          },
        ),
        actions: <Widget>[
          AppIconButton(
            outlined: true,
            tooltip: 'Add workspace path',
            onPressed: _canAddPath ? _addPath : null,
            icon: FluentIcons.add_20_regular,
          ),
        ],
      ),
      if (_paths.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'No workspace folders have been added yet.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        )
      else
        for (int rootIndex = 0; rootIndex < _paths.length; rootIndex++)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.row),
            child: _buildPathRow(rootIndex, _paths[rootIndex]),
          ),
    ],
  );

  Widget _buildPathRow(int rootIndex, String path) {
    final bool ragEnabled = _isRagEnabled(path);
    final bool isReindexing = _reindexingRootIndexes.contains(rootIndex);
    return AppListRow(
      dense: true,
      flush: true,
      onTap: null,
      trailingInteractive: true,
      title: path,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('RAG'),
          const SizedBox(width: 2),
          AppSwitch(
            compact: true,
            value: ragEnabled,
            onChanged: _canPersistRag
                ? (bool enabled) => unawaited(_toggleRag(path, enabled))
                : null,
            semanticLabel: 'Enable RAG for $path',
          ),
          AppSpacing.controlGap,
          AppIconButton(
            outlined: true,
            tooltip: 'Reindex workspace folder: $path',
            onPressed: _isBusy || !widget.controller.isConnected || !ragEnabled
                ? null
                : () => unawaited(_reindexRoot(rootIndex, path)),
            busy: isReindexing,
            icon: FluentIcons.arrow_sync_20_regular,
          ),
          AppSpacing.controlGap,
          AppIconButton(
            outlined: true,
            tooltip: 'Remove workspace path: $path',
            onPressed: _isBusy ? null : () => _removePath(path),
            icon: FluentIcons.dismiss_20_regular,
          ),
        ],
      ),
    );
  }

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
        AppSwitch(
          value: value,
          onChanged: _isBusy ? null : onChanged,
          semanticLabel: title,
        ),
      ],
    ),
  );

  Widget _buildMetadata(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      AppFieldLabel('UUID'),
      AppFieldRow(
        field: AppTextField(
          key: ValueKey<String>(widget.workspace.uuid),
          initialValue: widget.workspace.uuid,
          readOnly: true,
        ),
        actions: <Widget>[
          AppIconButton(
            outlined: true,
            tooltip: 'Copy workspace UUID',
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: widget.workspace.uuid),
              );
              if (context.mounted) {
                showAppSnack(context, 'Workspace UUID copied');
              }
            },
            icon: FluentIcons.copy_20_regular,
          ),
        ],
      ),
      const SizedBox(height: 16),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AppFieldLabel('Created'),
                Text(_formatDate(widget.workspace.createdAt)),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AppFieldLabel('Updated'),
                Text(_formatDate(widget.workspace.updatedAt)),
              ],
            ),
          ),
        ],
      ),
    ],
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

  bool _isRagEnabled(String path) {
    final Object? rawRoots = _rawRag['roots'];
    if (rawRoots is! List) return true;
    for (final Object? rawRoot in rawRoots) {
      if (rawRoot is! Map) continue;
      final Map<String, dynamic> root = _objectValue(rawRoot);
      if (_samePath(root['path'], path) && root['enabled'] == false) {
        return false;
      }
    }
    return true;
  }

  void _setRagEnabled(String path, bool enabled) {
    final Map<String, dynamic> value = _deepCopy(_rawRag);
    final Object? rawRoots = value['roots'];
    if (enabled && rawRoots is! List) return;
    final List<dynamic> roots = rawRoots is List
        ? List<dynamic>.from(rawRoots)
        : <dynamic>[];
    final int previousLength = roots.length;
    roots.removeWhere((dynamic rawRoot) {
      if (rawRoot is! Map) return false;
      return _samePath(_objectValue(rawRoot)['path'], path);
    });
    if (enabled && roots.length == previousLength) return;
    if (!enabled) roots.add(<String, dynamic>{'path': path, 'enabled': false});
    value['roots'] = roots;
    _rawRag = value;
  }

  static bool _samePath(Object? left, String right) =>
      left is String &&
      left.replaceAll('\\', '/').toLowerCase() ==
          right.replaceAll('\\', '/').toLowerCase();

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
                      AppIconButton(
                        outlined: true,
                        tooltip: 'Cancel workspace creation',
                        onPressed: _isCreating
                            ? null
                            : widget.controller.cancelWorkspaceCreation,
                        icon: FluentIcons.dismiss_20_regular,
                      ),
                      AppSpacing.controlGap,
                      AppIconButton(
                        outlined: true,
                        tooltip: 'Create workspace',
                        onPressed: _canCreate ? _create : null,
                        busy: _isCreating,
                        icon: FluentIcons.add_20_regular,
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
                      AppTextField(
                        label: 'Name',
                        controller: _nameController,
                        autofocus: true,
                        enabled: !_isCreating,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _create(),
                        hintText: 'Workspace name',
                      ),
                      AppTextField(
                        label: 'Description',
                        controller: _descriptionController,
                        enabled: !_isCreating,
                        minLines: 4,
                        maxLines: 8,
                        hintText: 'Optional description',
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
