import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine_llm_provider.dart';

typedef CreateThreadCallback = Future<void> Function({
  String? title,
  String? toolsConfig,
});
typedef UpdateThreadCallback = Future<void> Function({
  required ThreadInfo thread,
  String? title,
  String? toolsConfig,
  required bool clearToolsConfig,
});

final class EngineChatPanel extends StatefulWidget {
  const EngineChatPanel({
    required this.provider,
    required this.isComposerEnabled,
    this.workspace,
    this.thread,
    this.onCreateThread,
    this.onUpdateThread,
    this.title,
    this.useNeutralUserBubbleForeground = false,
    super.key,
  });

  final EngineLlmProvider provider;
  final bool isComposerEnabled;
  final Workspace? workspace;
  final ThreadInfo? thread;
  final CreateThreadCallback? onCreateThread;
  final UpdateThreadCallback? onUpdateThread;
  final String? title;
  final bool useNeutralUserBubbleForeground;

  @override
  State<EngineChatPanel> createState() => _EngineChatPanelState();
}

final class _EngineChatPanelState extends State<EngineChatPanel> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<ModelInfo> _models = const <ModelInfo>[];
  bool _isSending = false;
  Object? _error;
  int _modelLoadVersion = 0;

  @override
  void initState() {
    super.initState();
    widget.provider.addListener(_onProviderChanged);
    if (widget.isComposerEnabled) unawaited(_loadModels());
    _scheduleScrollToBottom();
  }

  @override
  void didUpdateWidget(covariant EngineChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) {
      oldWidget.provider.removeListener(_onProviderChanged);
      widget.provider.addListener(_onProviderChanged);
      _models = const <ModelInfo>[];
      _error = null;
      if (widget.isComposerEnabled) unawaited(_loadModels());
      _scheduleScrollToBottom();
      return;
    }
    if (!oldWidget.isComposerEnabled && widget.isComposerEnabled) {
      _error = null;
      unawaited(_loadModels());
    }
  }

  Future<void> _loadModels() async {
    final int version = ++_modelLoadVersion;
    try {
      final List<ModelInfo> loaded = await widget.provider.repository
          .listModels();
      if (!mounted || version != _modelLoadVersion) return;
      setState(() => _models = loaded);
    } on Object catch (error) {
      if (!mounted || version != _modelLoadVersion) return;
      setState(() => _error = error);
    }
  }

  void _onProviderChanged() {
    if (mounted) setState(() {});
    _scheduleScrollToBottom();
  }

  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final String content = _composer.text.trim();
    if (!widget.isComposerEnabled || content.isEmpty || _isSending) return;
    _composer.clear();
    setState(() {
      _isSending = true;
      _error = null;
    });
    try {
      await for (final String _ in widget.provider.sendMessageStream(content)) {
        // Provider notifications redraw the streaming response.
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _isSending = false);
      _scheduleScrollToBottom();
    }
  }

  Future<void> _createThread() async {
    final CreateThreadCallback? create = widget.onCreateThread;
    final Workspace? workspace = widget.workspace;
    if (create == null || workspace == null) return;
    final _ThreadSettingsDraft? draft = await showDialog<_ThreadSettingsDraft>(
      context: context,
      builder: (BuildContext context) => _ThreadSettingsDialog(
        repository: widget.provider.repository,
        workspace: workspace,
      ),
    );
    if (draft == null || !mounted) return;
    setState(() => _error = null);
    try {
      await create(title: draft.title, toolsConfig: draft.toolsConfig);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _editThread() async {
    final UpdateThreadCallback? update = widget.onUpdateThread;
    final Workspace? workspace = widget.workspace;
    final ThreadInfo? thread = widget.thread;
    if (update == null || workspace == null || thread == null) return;
    final _ThreadSettingsDraft? draft = await showDialog<_ThreadSettingsDraft>(
      context: context,
      builder: (BuildContext context) => _ThreadSettingsDialog(
        repository: widget.provider.repository,
        workspace: workspace,
        thread: thread,
      ),
    );
    if (draft == null || !mounted) return;
    setState(() => _error = null);
    try {
      await update(
        thread: thread,
        title: draft.title,
        toolsConfig: draft.toolsConfig,
        clearToolsConfig: draft.useWorkspaceDefaults,
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _modelLoadVersion++;
    widget.provider.removeListener(_onProviderChanged);
    _composer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<EngineChatMessage> messages = widget.provider.history.toList(
      growable: false,
    );
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ChatHeader(
            title: widget.title?.trim().isNotEmpty ?? false
                ? widget.title!
                : 'New thread',
            canCreateThread: widget.onCreateThread != null,
            canEditThread:
                widget.thread != null && widget.onUpdateThread != null,
            onCreateThread: _createThread,
            onEditThread: _editThread,
          ),
          Expanded(
            child: messages.isEmpty
                ? const _EmptyChat()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                    itemCount: messages.length,
                    itemBuilder: (BuildContext context, int index) =>
                        _MessageBubble(
                          message: messages[index],
                          timestamp: widget.provider.timestampFor(
                            messages[index],
                          ),
                          useNeutralUserBubbleForeground:
                              widget.useNeutralUserBubbleForeground,
                        ),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: Text(
                '$_error',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
          _Composer(
            controller: _composer,
            models: _models,
            selectedModelId: widget.provider.modelId,
            isSending: _isSending,
            enabled: widget.isComposerEnabled,
            onModelSelected: widget.provider.selectModel,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

final class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.title,
    required this.canCreateThread,
    required this.canEditThread,
    required this.onCreateThread,
    required this.onEditThread,
  });

  final String title;
  final bool canCreateThread;
  final bool canEditThread;
  final VoidCallback onCreateThread;
  final VoidCallback onEditThread;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: 'New thread',
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            padding: EdgeInsets.zero,
            style: _compactControlStyle(context),
            onPressed: canCreateThread ? onCreateThread : null,
            icon: const Icon(FluentIcons.add_20_regular, size: 20),
          ),
          const SizedBox(width: 4),
          SizedBox.square(
            dimension: 32,
            child: PopupMenuButton<_ThreadMenuAction>(
              tooltip: 'More thread options',
              enabled: canEditThread,
              padding: EdgeInsets.zero,
              style: _compactControlStyle(context),
              icon: const Icon(
                FluentIcons.more_horizontal_20_regular,
                size: 20,
              ),
              onSelected: (_ThreadMenuAction action) {
                if (action == _ThreadMenuAction.settings) onEditThread();
              },
              itemBuilder: (BuildContext context) =>
                  const <PopupMenuEntry<_ThreadMenuAction>>[
                    PopupMenuItem<_ThreadMenuAction>(
                      value: _ThreadMenuAction.settings,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          FluentIcons.settings_20_regular,
                          size: 18,
                        ),
                        title: Text('Thread settings and tools'),
                      ),
                    ),
                  ],
            ),
          ),
        ],
      ),
    ),
  );
}

enum _ThreadMenuAction { settings }

final class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Text(
        'Ask anything…',
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.useNeutralUserBubbleForeground,
    this.timestamp,
  });

  final EngineChatMessage message;
  final DateTime? timestamp;
  final bool useNeutralUserBubbleForeground;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool isUser = message.origin == EngineChatMessageOrigin.user;
    final bool useNeutralForeground = isUser && useNeutralUserBubbleForeground;
    final Color? messageForeground = useNeutralForeground
        ? colors.onPrimaryContainer
        : null;
    final Color metadataForeground = useNeutralForeground
        ? colors.onPrimaryContainer.withValues(alpha: 0.7)
        : colors.onSurfaceVariant;
    final String text = message.text;
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SelectableText(
          text,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(height: 1.45, color: messageForeground),
        ),
        Row(
          children: <Widget>[
            if (timestamp != null)
              Text(
                _formatTimestamp(timestamp!),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: metadataForeground),
              ),
            const Spacer(),
            IconButton(
              tooltip: 'Copy message',
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              padding: EdgeInsets.zero,
              style: useNeutralForeground
                  ? IconButton.styleFrom(
                      foregroundColor: metadataForeground,
                      disabledForegroundColor: colors.onPrimaryContainer
                          .withValues(alpha: 0.38),
                    )
                  : _compactControlStyle(context),
              onPressed: text.isEmpty
                  ? null
                  : () => Clipboard.setData(ClipboardData(text: text)),
              icon: const Icon(FluentIcons.copy_16_regular, size: 14),
            ),
          ],
        ),
      ],
    );
    if (!isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(width: double.infinity, child: content),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: 0.82,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(13, 11, 8, 7),
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: content,
        ),
      ),
    );
  }
}

final class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.models,
    required this.selectedModelId,
    required this.isSending,
    required this.enabled,
    required this.onModelSelected,
    required this.onSend,
  });

  final TextEditingController controller;
  final List<ModelInfo> models;
  final String? selectedModelId;
  final bool isSending;
  final bool enabled;
  final ValueChanged<String?> onModelSelected;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final String? effectiveModelId = selectedModelId?.trim().isNotEmpty ?? false
        ? selectedModelId
        : null;
    final bool hasSelectedModel = models.any(
      (ModelInfo model) => model.id == effectiveModelId,
    );
    final bool interactive = enabled && !isSending;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: controller,
            enabled: interactive,
            minLines: 3,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              hintText: enabled ? 'Ask anything…' : 'Engine unavailable',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                      clipBehavior: Clip.antiAlias,
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          borderRadius: BorderRadius.circular(4),
                          focusColor: colors.secondaryContainer,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          value: effectiveModelId ?? '',
                          items: <DropdownMenuItem<String>>[
                            const DropdownMenuItem<String>(
                              value: '',
                              child: Text(
                                'Default model',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (effectiveModelId != null && !hasSelectedModel)
                              DropdownMenuItem<String>(
                                value: effectiveModelId,
                                child: Text(
                                  effectiveModelId,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            for (final ModelInfo model in models)
                              DropdownMenuItem<String>(
                                value: model.id,
                                child: Text(
                                  model.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: interactive
                              ? (String? value) => onModelSelected(
                                  value == null || value.isEmpty ? null : value,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: enabled ? 'Send' : 'Engine unavailable',
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: interactive ? onSend : null,
                  style: _compactControlStyle(context),
                  icon: isSending
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(FluentIcons.send_20_regular, size: 20),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatTimestamp(DateTime value) {
  final DateTime local = value.toLocal();
  final int hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final String minute = local.minute.toString().padLeft(2, '0');
  final String day = local.day.toString().padLeft(2, '0');
  final String month = local.month.toString().padLeft(2, '0');
  final String period = local.hour < 12 ? 'am' : 'pm';
  return '$day/$month/${local.year} $hour:$minute $period';
}

ButtonStyle _compactControlStyle(BuildContext context) => IconButton.styleFrom(
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
);

final class _ThreadSettingsDraft {
  const _ThreadSettingsDraft({
    required this.title,
    required this.toolsConfig,
    required this.useWorkspaceDefaults,
  });

  final String? title;
  final String? toolsConfig;
  final bool useWorkspaceDefaults;
}

final class _ThreadSettingsDialog extends StatefulWidget {
  const _ThreadSettingsDialog({
    required this.repository,
    required this.workspace,
    this.thread,
  });

  final EngineRepository repository;
  final Workspace workspace;
  final ThreadInfo? thread;

  @override
  State<_ThreadSettingsDialog> createState() => _ThreadSettingsDialogState();
}

final class _ThreadSettingsDialogState extends State<_ThreadSettingsDialog> {
  late final TextEditingController _titleController;
  ToolCatalog? _catalog;
  Map<String, Map<String, bool>> _builtinTools = <String, Map<String, bool>>{};
  Map<String, bool> _configuredTools = <String, bool>{};
  bool _useWorkspaceDefaults = true;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.thread?.title ?? '');
    _useWorkspaceDefaults = widget.thread?.toolsConfig == null;
    unawaited(_loadCatalog());
  }

  Future<void> _loadCatalog() async {
    try {
      final ToolCatalog catalog = await widget.repository.rest
          .listToolCatalog();
      final Map<String, dynamic> config = _decodeConfig(
        widget.thread?.toolsConfig ?? widget.workspace.toolsConfig,
      );
      final Map<String, dynamic> builtin = _objectValue(config['builtin']);
      final bool builtinEnabled = config['builtin_enabled'] is bool
          ? config['builtin_enabled'] as bool
          : true;
      final Map<String, Map<String, bool>> builtinTools =
          <String, Map<String, bool>>{};
      for (final MapEntry<String, List<BuiltinToolCatalogEntry>> group
          in catalog.builtin.entries) {
        final Map<String, dynamic> groupConfig = _objectValue(
          builtin[group.key],
        );
        final bool groupEnabled = groupConfig['enabled'] is bool
            ? groupConfig['enabled'] as bool
            : true;
        final Map<String, dynamic> tools = _objectValue(groupConfig['tools']);
        builtinTools[group.key] = <String, bool>{
          for (final BuiltinToolCatalogEntry tool in group.value)
            tool.name:
                builtinEnabled &&
                groupEnabled &&
                (tools[tool.name] is bool ? tools[tool.name] as bool : true),
        };
      }
      final Map<String, dynamic> configured = _objectValue(
        config['configured'],
      );
      final bool configuredEnabled = config['configured_enabled'] is bool
          ? config['configured_enabled'] as bool
          : true;
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _builtinTools = builtinTools;
        _configuredTools = <String, bool>{
          for (final ToolRegistryEntry tool in catalog.configured)
            tool.uuid:
                configuredEnabled &&
                (configured[tool.uuid] is bool
                    ? configured[tool.uuid] as bool
                    : true),
        };
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  String _serializeTools() => jsonEncode(<String, dynamic>{
    'builtin_enabled': true,
    'configured_enabled': true,
    'builtin': <String, dynamic>{
      for (final MapEntry<String, Map<String, bool>> group
          in _builtinTools.entries)
        group.key: <String, dynamic>{'enabled': true, 'tools': group.value},
    },
    'configured': _configuredTools,
  });

  void _submit() {
    final String title = _titleController.text.trim();
    Navigator.pop(
      context,
      _ThreadSettingsDraft(
        title: title.isEmpty ? null : title,
        toolsConfig: _useWorkspaceDefaults ? null : _serializeTools(),
        useWorkspaceDefaults: _useWorkspaceDefaults,
      ),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.thread == null ? 'New thread' : 'Thread settings'),
    content: SizedBox(
      width: 560,
      height: 520,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _titleController,
            autofocus: widget.thread == null,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 10),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use workspace tool defaults'),
            subtitle: const Text(
              'Turn this off to override the tools available to this thread.',
            ),
            value: _useWorkspaceDefaults,
            onChanged: (bool? value) =>
                setState(() => _useWorkspaceDefaults = value ?? false),
          ),
          const SizedBox(height: 6),
          Expanded(child: _buildTools(context)),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _loading ? null : _submit,
        child: Text(widget.thread == null ? 'Create' : 'Save'),
      ),
    ],
  );

  Widget _buildTools(BuildContext context) {
    if (_useWorkspaceDefaults) {
      return Center(
        child: Text(
          'This thread inherits ${widget.workspace.name} tool settings.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final Object error) {
      return Center(child: Text("Couldn't load tools: $error"));
    }
    final ToolCatalog? catalog = _catalog;
    if (catalog == null) return const SizedBox.shrink();
    return ListView(
      children: <Widget>[
        Text('Built-in tools', style: Theme.of(context).textTheme.titleSmall),
        for (final MapEntry<String, List<BuiltinToolCatalogEntry>> group
            in catalog.builtin.entries) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
            child: Text(
              _displayName(group.key),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          for (final BuiltinToolCatalogEntry tool in group.value)
            CheckboxListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(_displayName(tool.name)),
              subtitle: tool.doc.isEmpty ? null : Text(tool.doc),
              value: _builtinTools[group.key]?[tool.name] ?? true,
              onChanged: (bool? value) => setState(
                () => _builtinTools[group.key]![tool.name] = value ?? false,
              ),
            ),
        ],
        const SizedBox(height: 12),
        Text('Custom tools', style: Theme.of(context).textTheme.titleSmall),
        if (catalog.configured.isEmpty)
          const ListTile(title: Text('No custom tools are configured.')),
        for (final ToolRegistryEntry tool in catalog.configured)
          CheckboxListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text(
              tool.alias?.trim().isNotEmpty ?? false ? tool.alias! : tool.name,
            ),
            subtitle: Text(tool.uuid),
            value: _configuredTools[tool.uuid] ?? true,
            onChanged: (bool? value) =>
                setState(() => _configuredTools[tool.uuid] = value ?? false),
          ),
      ],
    );
  }

  static Map<String, dynamic> _decodeConfig(String? raw) {
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

  static String _displayName(String value) => value
      .replaceAll('_', ' ')
      .split(' ')
      .where((String word) => word.isNotEmpty)
      .map(
        (String word) =>
            '${word.substring(0, 1).toUpperCase()}${word.substring(1)}',
      )
      .join(' ');
}
