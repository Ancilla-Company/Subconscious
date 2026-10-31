import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../../dashboard/controller/dashboard_controller.dart';
import '../../tools/presentation/tool_policy_list.dart';

/// The main panel of the Agents section: the form of the selected agent, the
/// form for a new one, or a hint when neither is open. Built from the shared
/// form kit like every other settings form.
final class AgentMainPanel extends StatelessWidget {
  const AgentMainPanel({required this.controller, super.key});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.isCreatingAgent) {
      return _AgentForm(key: const ValueKey<String>('new'), controller: controller);
    }
    final AgentInfo? agent = controller.selectedAgent;
    if (agent == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: const Center(
          child: Text('Select an agent to edit it, or create a new one.'),
        ),
      );
    }
    return _AgentForm(
      key: ValueKey<String>(agent.uuid),
      controller: controller,
      agent: agent,
    );
  }
}

final class _AgentForm extends StatefulWidget {
  const _AgentForm({required this.controller, this.agent, super.key});

  final DashboardController controller;

  /// Null while creating.
  final AgentInfo? agent;

  @override
  State<_AgentForm> createState() => _AgentFormState();
}

final class _AgentFormState extends State<_AgentForm> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _instructionsController = TextEditingController();
  List<ModelInfo> _models = const <ModelInfo>[];
  ToolCatalog? _catalog;
  String? _modelId;

  /// The workspace the agent belongs to; empty for an account-wide agent.
  String _scope = '';
  bool _enabled = true;

  /// Off: the agent uses the workspace's tool policy and approval rules.
  bool _customize = false;
  Map<String, dynamic> _rawTools = <String, dynamic>{};
  Map<String, dynamic> _rawApproval = <String, dynamic>{};
  Map<String, bool> _builtinGroups = <String, bool>{};
  Map<String, Map<String, bool>> _builtinTools = <String, Map<String, bool>>{};
  Map<String, bool> _configuredTools = <String, bool>{};
  bool _builtinEnabled = true;
  bool _configuredEnabled = true;
  bool _approveCreate = true;
  bool _approveRead = true;
  bool _approveUpdate = true;
  bool _approveDelete = true;
  bool _isSynchronizing = false;
  bool _isLoadingOptions = true;
  bool _isSaving = false;
  bool _isDeleting = false;
  Object? _error;
  late String _savedSignature;

  AgentInfo? get _agent => widget.agent;
  bool get _isNew => _agent == null;
  bool get _isBusy => _isSaving || _isDeleting;
  String get _name => _nameController.text.trim();
  bool get _isDirty => _signature() != _savedSignature;
  bool get _canSave =>
      widget.controller.isConnected &&
      !_isBusy &&
      _name.isNotEmpty &&
      (_isNew || _isDirty);

  @override
  void initState() {
    super.initState();
    _loadFrom(_agent);
    for (final TextEditingController controller in <TextEditingController>[
      _nameController,
      _descriptionController,
      _instructionsController,
    ]) {
      controller.addListener(_onFieldChanged);
    }
    unawaited(_loadOptions());
  }

  @override
  void didUpdateWidget(covariant _AgentForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reload (another device, the assistant) brings a new copy of the agent.
    // Unsaved edits win over it.
    if (!identical(oldWidget.agent, widget.agent) && !_isDirty) {
      setState(() => _loadFrom(_agent));
    }
  }

  Workspace? _workspace(String uuid) {
    for (final Workspace workspace in widget.controller.workspaces) {
      if (workspace.uuid == uuid) return workspace;
    }
    return null;
  }

  void _loadFrom(AgentInfo? agent) {
    _isSynchronizing = true;
    _nameController.text = agent?.name ?? '';
    _descriptionController.text = agent?.description ?? '';
    _instructionsController.text = agent?.instructions ?? '';
    _modelId = agent?.defaultModelId;
    _scope = agent == null
        ? widget.controller.activeWorkspace?.uuid ?? ''
        : agent.workspaceUuid ?? '';
    _enabled = agent?.enabled ?? true;
    _customize =
        agent != null &&
        (agent.toolsConfig != null || agent.approvalConfig != null);
    _rebase(agent);
    _isSynchronizing = false;
    _savedSignature = _signature();
  }

  /// Takes the tool policy and approval rules to edit from the agent, or from
  /// the workspace it belongs to while it has none of its own.
  void _rebase(AgentInfo? agent) {
    final Workspace? workspace = _scope.isEmpty ? null : _workspace(_scope);
    _rawTools = _decode(agent?.toolsConfig ?? workspace?.toolsConfig);
    _rawApproval = _decode(agent?.approvalConfig ?? workspace?.approvalConfig);
    _builtinEnabled = _readBool(_rawTools, 'builtin_enabled', fallback: true);
    _configuredEnabled = _readBool(
      _rawTools,
      'configured_enabled',
      fallback: true,
    );
    _approveCreate = _readBool(_rawApproval, 'create', fallback: true);
    _approveRead = _readBool(_rawApproval, 'read', fallback: true);
    _approveUpdate = _readBool(_rawApproval, 'update', fallback: true);
    _approveDelete = _readBool(_rawApproval, 'delete', fallback: true);
    if (_catalog case final ToolCatalog catalog) _populateToolPolicy(catalog);
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
      _catalog = catalog;
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

  String _signature() => jsonEncode(<String, dynamic>{
    'name': _name,
    'description': _descriptionController.text.trim(),
    'instructions': _instructionsController.text.trim(),
    'model': _modelId,
    'scope': _scope,
    'enabled': _enabled,
    'customize': _customize,
    'approve': <bool>[
      _approveCreate,
      _approveRead,
      _approveUpdate,
      _approveDelete,
    ],
    'builtinEnabled': _builtinEnabled,
    'configuredEnabled': _configuredEnabled,
    'builtinGroups': _builtinGroups,
    'builtinTools': _builtinTools,
    'configuredTools': _configuredTools,
  });

  AgentRequest _request() {
    final String description = _descriptionController.text.trim();
    final String instructions = _instructionsController.text.trim();
    return AgentRequest(
      name: _name,
      description: description.isEmpty ? null : description,
      instructions: instructions.isEmpty ? null : instructions,
      defaultModelId: _modelId,
      toolsConfig: _customize ? _serializeTools() : null,
      approvalConfig: _customize ? _serializeApproval() : null,
      workspaceUuid: _scope.isEmpty ? null : _scope,
      enabled: _enabled,
    );
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      final AgentInfo? agent = _agent;
      if (agent == null) {
        await widget.controller.createAgent(_request());
      } else {
        await widget.controller.updateAgent(agent, _request());
        if (mounted) _savedSignature = _signature();
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final AgentInfo? agent = _agent;
    if (agent == null || _isBusy || !widget.controller.isConnected) return;
    final bool confirmed =
        await showAppDialog<bool>(
          context: context,
          builder: (BuildContext context) => AppDialog(
            title: 'Delete agent?',
            content: Text('Delete “${agent.name}”? This cannot be undone.'),
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
      await widget.controller.deleteAgent(agent);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _isDeleting = false;
          _error = error;
        });
      }
    }
  }

  @override
  void dispose() {
    for (final TextEditingController controller in <TextEditingController>[
      _nameController,
      _descriptionController,
      _instructionsController,
    ]) {
      controller
        ..removeListener(_onFieldChanged)
        ..dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // A Material (not a ColoredBox) so the switch tiles can paint on it.
    return Material(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHeader(context),
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
                        autofocus: _isNew,
                        textInputAction: TextInputAction.next,
                        hintText: 'Agent name',
                      ),
                      AppTextField(
                        label: 'Description',
                        controller: _descriptionController,
                        enabled: !_isBusy,
                        minLines: 2,
                        maxLines: 4,
                        hintText: 'What this agent is for',
                      ),
                      AppTextField(
                        label: 'Instructions',
                        controller: _instructionsController,
                        enabled: !_isBusy,
                        minLines: 6,
                        maxLines: 16,
                        hintText: 'How this agent should behave',
                      ),
                      const AppFieldLabel('Default model'),
                      _buildModelPicker(),
                      const AppFieldLabel('Available in'),
                      _buildScopePicker(),
                      AppSwitchTile(
                        title: 'Enabled',
                        value: _enabled,
                        onChanged: _isBusy
                            ? null
                            : (bool value) => _change(() => _enabled = value),
                      ),
                      AppSwitchTile(
                        title: 'Customize tools and permissions',
                        subtitle: _customize
                            ? 'This agent has its own tool allow list and approval rules.'
                            : 'Off: use the tool policy and approval rules of the workspace.',
                        value: _customize,
                        onChanged: _isBusy
                            ? null
                            : (bool value) => _change(() {
                                _customize = value;
                                if (value) _rebase(_agent);
                              }),
                      ),
                      if (_customize) ..._buildPolicy(context, colors),
                      if (_agent case final AgentInfo agent) ...<Widget>[
                        const SizedBox(height: 20),
                        _buildMetadata(agent),
                      ],
                      if (_error case final Object error)
                        AppFormError(
                          error: 'Agent operation failed: ${describe(error)}',
                        ),
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

  List<Widget> _buildPolicy(BuildContext context, ColorScheme colors) =>
      <Widget>[
        const AppFieldLabel('Require approval'),
        AppSwitchTile(
          title: 'Create',
          value: _approveCreate,
          onChanged: _isBusy
              ? null
              : (bool value) => _change(() => _approveCreate = value),
        ),
        AppSwitchTile(
          title: 'Read',
          value: _approveRead,
          onChanged: _isBusy
              ? null
              : (bool value) => _change(() => _approveRead = value),
        ),
        AppSwitchTile(
          title: 'Update',
          value: _approveUpdate,
          onChanged: _isBusy
              ? null
              : (bool value) => _change(() => _approveUpdate = value),
        ),
        AppSwitchTile(
          title: 'Delete',
          value: _approveDelete,
          onChanged: _isBusy
              ? null
              : (bool value) => _change(() => _approveDelete = value),
        ),
        const AppFieldLabel('Tool allow list'),
        Text(
          'Choose the built-in tool groups and individual functions this agent may use.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
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
          catalog: _catalog,
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
          onBuiltinToolChanged: (String group, String tool, bool value) =>
              _change(() => _builtinTools[group]![tool] = value),
          onConfiguredToolChanged: (String uuid, bool value) =>
              _change(() => _configuredTools[uuid] = value),
        ),
      ];

  Widget _buildHeader(BuildContext context) => SizedBox(
    height: 56,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Align(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 750),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _isNew ? 'New agent' : 'Edit agent',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (_isNew)
                AppIconButton(
                  outlined: true,
                  tooltip: 'Cancel agent creation',
                  onPressed: _isBusy
                      ? null
                      : widget.controller.cancelAgentCreation,
                  icon: FluentIcons.dismiss_20_regular,
                )
              else
                AppIconButton(
                  outlined: true,
                  tooltip: 'Delete agent',
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
                tooltip: _isNew ? 'Create agent' : 'Save agent',
                onPressed: _canSave ? _save : null,
                busy: _isSaving,
                icon: _isNew
                    ? FluentIcons.add_20_regular
                    : FluentIcons.save_20_regular,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildModelPicker() {
    final String? value = _modelId?.trim().isNotEmpty ?? false
        ? _modelId
        : null;
    final bool known = _models.any((ModelInfo model) => model.id == value);
    return AppDropdownField<String>(
      key: ValueKey<String>('model:${value ?? ''}'),
      value: value ?? '',
      items: <DropdownMenuItem<String>>[
        const DropdownMenuItem<String>(
          value: '',
          child: Text('Workspace default', overflow: TextOverflow.ellipsis),
        ),
        if (value != null && !known)
          DropdownMenuItem<String>(
            value: value,
            child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        for (final ModelInfo model in _models.where(
          (ModelInfo m) => m.isChatModel,
        ))
          DropdownMenuItem<String>(
            value: model.id,
            child: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _isBusy
          ? null
          : (String? selected) {
              if (selected == null) return;
              _change(() => _modelId = selected.isEmpty ? null : selected);
            },
    );
  }

  Widget _buildScopePicker() {
    final List<Workspace> workspaces = widget.controller.workspaces;
    final bool known =
        _scope.isEmpty || workspaces.any((Workspace w) => w.uuid == _scope);
    return AppDropdownField<String>(
      key: ValueKey<String>('scope:$_scope'),
      value: _scope,
      items: <DropdownMenuItem<String>>[
        const DropdownMenuItem<String>(
          value: '',
          child: Text(
            'Every workspace (account-wide)',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (!known)
          DropdownMenuItem<String>(
            value: _scope,
            child: const Text('Unknown workspace'),
          ),
        for (final Workspace workspace in workspaces)
          DropdownMenuItem<String>(
            value: workspace.uuid,
            child: Text(
              'Only ${workspace.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _isBusy
          ? null
          : (String? selected) {
              if (selected == null) return;
              _change(() {
                _scope = selected;
                // Without settings of its own the agent follows the workspace.
                if (!_customize) _rebase(_agent);
              });
            },
    );
  }

  Widget _buildMetadata(AgentInfo agent) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const AppFieldLabel('UUID'),
      AppFieldRow(
        field: AppTextField(
          key: ValueKey<String>(agent.uuid),
          initialValue: agent.uuid,
          readOnly: true,
        ),
        actions: <Widget>[
          AppIconButton(
            outlined: true,
            tooltip: 'Copy agent UUID',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: agent.uuid));
              if (mounted) showAppSnack(context, 'Agent UUID copied');
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
                const AppFieldLabel('Created'),
                Text(_formatDate(agent.createdAt)),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const AppFieldLabel('Updated'),
                Text(_formatDate(agent.updatedAt)),
              ],
            ),
          ),
        ],
      ),
    ],
  );

  static String describe(Object error) =>
      error is StateError ? error.message.toString() : '$error';

  static Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
    try {
      return _objectValue(jsonDecode(raw));
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

  static String _formatDate(DateTime? value) {
    if (value == null) return '—';
    final DateTime local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
