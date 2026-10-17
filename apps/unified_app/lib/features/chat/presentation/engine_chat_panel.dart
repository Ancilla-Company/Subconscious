import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../editor/presentation/markdown/markdown_preview.dart';
import '../../hive/executor_selection.dart';
import '../../voice/voice_controller.dart';
import '../engine_llm_provider.dart';
import 'executor_widgets.dart';
import '../../settings/presentation/settings_main_panel.dart';

typedef MaterializeThreadDraftCallback = Future<EngineLlmProvider> Function(
  String firstMessage,
);
typedef UpdateThreadDraftCallback = void Function({
  String? title,
  String? toolsConfig,
});
typedef UpdateThreadCallback = Future<void> Function({
  required ThreadInfo thread,
  String? title,
  String? defaultModelId,
  String? toolsConfig,
  required bool clearToolsConfig,
});

final class EngineChatPanel extends StatefulWidget {
  const EngineChatPanel({
    required this.provider,
    required this.isComposerEnabled,
    this.workspace,
    this.activeFile,
    this.thread,
    this.onCreateThread,
    this.onMaterializeThreadDraft,
    this.onUpdateThreadDraft,
    this.onUpdateThread,
    this.onRefreshActiveFile,
    this.toolApproval,
    this.onToolApproval,
    this.title,
    this.draftToolsConfig,
    this.useNeutralUserBubbleForeground = false,
    this.executors,
    super.key,
  });

  /// Where tasks can run. When null (no hive) the picker is not shown.
  final ExecutorDirectory? executors;
  final EngineLlmProvider provider;
  final bool isComposerEnabled;
  final Workspace? workspace;
  final ChatFileReference? activeFile;
  final ThreadInfo? thread;
  final VoidCallback? onCreateThread;
  final MaterializeThreadDraftCallback? onMaterializeThreadDraft;
  final UpdateThreadDraftCallback? onUpdateThreadDraft;
  final UpdateThreadCallback? onUpdateThread;
  final Future<void> Function()? onRefreshActiveFile;
  final ToolApprovalRequest? toolApproval;
  final ValueChanged<bool>? onToolApproval;
  final String? title;
  final String? draftToolsConfig;
  final bool useNeutralUserBubbleForeground;

  @override
  State<EngineChatPanel> createState() => _EngineChatPanelState();
}

final class _EngineChatPanelState extends State<EngineChatPanel> {
  late final TextEditingController _composer;
  late final VoiceController _voice;
  final FocusNode _composerFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  List<ModelInfo> _models = const <ModelInfo>[];
  List<WorkspaceFileMatch> _fileSuggestions = const <WorkspaceFileMatch>[];
  List<ChatAttachment> _attachments = const <ChatAttachment>[];
  _TagQuery? _tagQuery;
  Timer? _tagSearchDebounce;
  int _tagSearchVersion = 0;
  String? _workspaceDefaultModelId;
  bool _isStarting = false;
  bool _isUpdatingModel = false;
  bool _showThreadSettings = false;
  int _modelLoadVersion = 0;
  int _modelUpdateVersion = 0;
  int _workspaceDefaultLoadVersion = 0;

  @override
  void initState() {
    super.initState();
    _composer = _ComposerTextController()..addListener(_onComposerChanged);
    _voice = VoiceController(repository: () => widget.provider.repository)
      ..onError = (String message) {
        if (mounted) _showErrorToast(context, message);
      }
      ..addListener(_onVoiceChanged);
    _workspaceDefaultModelId = _normalizedModelId(
      widget.workspace?.defaultModelId,
    );
    if (widget.provider.modelId == null && _workspaceDefaultModelId != null) {
      widget.provider.modelId = _workspaceDefaultModelId;
    }
    widget.provider.addListener(_onProviderChanged);
    if (_workspaceDefaultModelId == null && widget.workspace != null) {
      unawaited(_loadWorkspaceDefaultModel());
    }
    if (widget.isComposerEnabled) unawaited(_loadModels());
    _bindExecutors();
    _scheduleScrollToBottom();
    // A turn that failed while another thread was open reports here.
    final Object? missed = widget.provider.lastError;
    if (missed != null && !widget.provider.isBusy) {
      widget.provider.lastError = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showErrorToast(context, "Couldn't send the message: $missed");
      });
    }
  }

  /// Applies the stored per thread executor choice and name lookup.
  void _bindExecutors() {
    final ExecutorDirectory? directory = widget.executors;
    if (directory == null) return;
    final EngineLlmProvider provider = widget.provider;
    provider.nodeNameOf = directory.nameOf;
    final String? thread = provider.threadUuid;
    if (thread == null) return;
    unawaited(provider.refreshTaskInfo());
    unawaited(() async {
      final String? stored = await directory.loadSelection(thread);
      if (stored != null && identical(provider, widget.provider)) {
        provider.selectExecutor(stored);
      }
    }());
  }

  void _selectExecutor(String? nodeId) {
    final ExecutorDirectory? directory = widget.executors;
    final EngineLlmProvider provider = widget.provider;
    provider.selectExecutor(nodeId);
    final String? thread = provider.threadUuid;
    if (directory != null && thread != null) {
      unawaited(directory.saveSelection(thread, nodeId));
    }
  }

  @override
  void didUpdateWidget(covariant EngineChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace?.uuid != widget.workspace?.uuid) {
      _tagSearchVersion++;
      _tagSearchDebounce?.cancel();
      _clearComposerContext();
      _tagQuery = null;
      _fileSuggestions = const <WorkspaceFileMatch>[];
      _attachments = const <ChatAttachment>[];
    }
    if (oldWidget.workspace?.uuid != widget.workspace?.uuid ||
        oldWidget.workspace?.defaultModelId !=
            widget.workspace?.defaultModelId) {
      _workspaceDefaultLoadVersion++;
      _workspaceDefaultModelId = _normalizedModelId(
        widget.workspace?.defaultModelId,
      );
      if (widget.provider.modelId == null && _workspaceDefaultModelId != null) {
        widget.provider.modelId = _workspaceDefaultModelId;
      }
      if (_workspaceDefaultModelId == null && widget.workspace != null) {
        unawaited(_loadWorkspaceDefaultModel());
      }
    }
    if (oldWidget.provider != widget.provider) {
      _modelUpdateVersion++;
      oldWidget.provider.removeListener(_onProviderChanged);
      widget.provider.addListener(_onProviderChanged);
      if (widget.provider.modelId == null && _workspaceDefaultModelId != null) {
        widget.provider.modelId = _workspaceDefaultModelId;
      }
      _models = const <ModelInfo>[];
      _isUpdatingModel = false;
      if (widget.isComposerEnabled) unawaited(_loadModels());
      _bindExecutors();
      _scheduleScrollToBottom();
      return;
    }
    if (!oldWidget.isComposerEnabled && widget.isComposerEnabled) {
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
      _voice.models = loaded;
    } on Object catch (error) {
      if (!mounted || version != _modelLoadVersion) return;
      _showErrorToast(context, "Couldn't load models: $error");
    }
  }

  Future<void> _loadWorkspaceDefaultModel() async {
    final Workspace? workspace = widget.workspace;
    if (workspace == null) return;
    final int version = ++_workspaceDefaultLoadVersion;
    try {
      final Workspace refreshed = await widget.provider.repository.rest
          .getWorkspace(workspace.uuid);
      final String? modelId = _normalizedModelId(refreshed.defaultModelId);
      if (!mounted ||
          version != _workspaceDefaultLoadVersion ||
          widget.workspace?.uuid != workspace.uuid ||
          modelId == null) {
        return;
      }
      setState(() => _workspaceDefaultModelId = modelId);
      if (widget.provider.modelId == null) {
        widget.provider.selectModel(modelId);
      }
    } on Object {
      // Keep the picker usable if the workspace refresh is unavailable.
    }
  }

  Future<void> _selectModel(String modelId) async {
    if (_isUpdatingModel || modelId.isEmpty) return;
    final EngineLlmProvider provider = widget.provider;
    final String? previousModelId = provider.modelId;
    if (previousModelId == modelId) return;

    final ThreadInfo? thread = widget.thread;
    final UpdateThreadCallback? update = widget.onUpdateThread;
    provider.selectModel(modelId);
    if (thread == null || update == null) return;

    final int version = ++_modelUpdateVersion;
    setState(() => _isUpdatingModel = true);
    try {
      await update(
        thread: thread,
        defaultModelId: modelId,
        clearToolsConfig: false,
      );
    } on Object catch (error) {
      if (!mounted ||
          version != _modelUpdateVersion ||
          !identical(widget.provider, provider) ||
          widget.thread?.uuid != thread.uuid) {
        return;
      }
      provider.selectModel(previousModelId);
      _showErrorToast(context, "Couldn't update the model: $error");
    } finally {
      if (mounted && version == _modelUpdateVersion) {
        setState(() => _isUpdatingModel = false);
      }
    }
  }

  void _onVoiceChanged() {
    if (mounted) setState(() {});
  }

  /// Records a prompt, then appends its transcript to the composer.
  Future<void> _toggleDictation() async {
    if (_voice.dictation == DictationState.recording) {
      final String? text = await _voice.finishDictation();
      if (text == null || text.trim().isEmpty || !mounted) return;
      final String current = _composer.text;
      final String joined = current.isEmpty || current.endsWith(' ')
          ? '$current${text.trim()}'
          : '$current ${text.trim()}';
      _composer.value = TextEditingValue(
        text: joined,
        selection: TextSelection.collapsed(offset: joined.length),
      );
      _composerFocusNode.requestFocus();
    } else {
      await _voice.startDictation();
    }
  }

  /// Starts or ends a realtime voice conversation in this thread.
  Future<void> _toggleRealtime() async {
    if (_voice.realtime != RealtimeState.off) {
      await _voice.stopRealtime();
      return;
    }
    try {
      EngineLlmProvider provider = widget.provider;
      if (widget.thread == null) {
        final MaterializeThreadDraftCallback? materialize =
            widget.onMaterializeThreadDraft;
        if (materialize == null) {
          throw StateError('The draft thread cannot be created.');
        }
        provider = await materialize('Voice conversation');
      }
      final String? thread = provider.threadUuid;
      if (thread == null) throw StateError('The thread is not ready.');
      await _voice.startRealtime(
        threadUuid: thread,
        agentModelId: provider.modelId,
      );
    } on Object catch (error) {
      if (mounted) _showErrorToast(context, "Couldn't start voice: $error");
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

  List<ChatFileReference> get _activeComposerReferences {
    final TextEditingController controller = _composer;
    return controller is _ComposerTextController
        ? controller.activeReferences
        : const <ChatFileReference>[];
  }

  void _clearComposerContext() {
    final TextEditingController controller = _composer;
    if (controller is _ComposerTextController) {
      controller.clearContext();
    } else {
      controller.clear();
    }
  }

  void _insertComposerFileTag(WorkspaceFileMatch match, _TagQuery query) {
    final TextEditingController controller = _composer;
    if (controller is _ComposerTextController) {
      controller.insertFileTag(match, query);
      return;
    }
    final String token = '#${match.relativePath} ';
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(query.start, query.end, token),
      selection: TextSelection.collapsed(offset: query.start + token.length),
    );
  }

  void _onComposerChanged() {
    final _TagQuery? query = _ComposerTextController.currentTagQuery(
      _composer.value,
    );
    _tagSearchDebounce?.cancel();
    if (query == null || widget.workspace == null) {
      if (_tagQuery != null || _fileSuggestions.isNotEmpty) {
        setState(() {
          _tagQuery = null;
          _fileSuggestions = const <WorkspaceFileMatch>[];
        });
      }
      return;
    }
    setState(() => _tagQuery = query);
    _tagSearchDebounce = Timer(
      const Duration(milliseconds: 160),
      () => unawaited(_searchFiles(query)),
    );
  }

  Future<void> _searchFiles(_TagQuery query) async {
    final Workspace? workspace = widget.workspace;
    if (workspace == null) return;
    final int version = ++_tagSearchVersion;
    try {
      final List<WorkspaceFileMatch> matches = await widget
          .provider
          .repository
          .rest
          .searchFiles(
            workspaceUuid: workspace.uuid,
            query: query.query,
            limit: 12,
          );
      if (!mounted || version != _tagSearchVersion || _tagQuery != query) {
        return;
      }
      setState(() => _fileSuggestions = matches);
    } on Object {
      if (!mounted || version != _tagSearchVersion) return;
      setState(() => _fileSuggestions = const <WorkspaceFileMatch>[]);
    }
  }

  void _selectTaggedFile(WorkspaceFileMatch match) {
    final _TagQuery? query = _tagQuery;
    if (query == null) return;
    _insertComposerFileTag(match, query);
    setState(() {
      _tagQuery = null;
      _fileSuggestions = const <WorkspaceFileMatch>[];
    });
    _composerFocusNode.requestFocus();
  }

  Future<void> _pickAttachments() async {
    try {
      final List<file_selector.XFile> picked = await file_selector.openFiles();
      if (picked.isEmpty) return;
      final List<ChatAttachment> next = <ChatAttachment>[..._attachments];
      int totalBytes = next.fold<int>(
        0,
        (int total, ChatAttachment item) => total + item.bytes.length,
      );
      for (final file_selector.XFile file in picked) {
        if (next.length >= 5) {
          throw StateError('A message can contain at most 5 attachments.');
        }
        final int length = await file.length();
        if (length > 2 * 1024 * 1024) {
          throw StateError('${file.name} exceeds the 2 MB attachment limit.');
        }
        final bytes = await file.readAsBytes();
        totalBytes += bytes.length;
        if (totalBytes > 8 * 1024 * 1024) {
          throw StateError('Attachments exceed the 8 MB total limit.');
        }
        next.add(
          ChatAttachment(
            id: 'attachment-${DateTime.now().microsecondsSinceEpoch}-${next.length}',
            name: file.name,
            mediaType: _attachmentMediaType(file.name),
            bytes: bytes,
          ),
        );
      }
      if (mounted) {
        setState(() => _attachments = next);
      }
    } on Object catch (error) {
      if (mounted) {
        _showErrorToast(context, "Couldn't attach the selected files: $error");
      }
    }
  }

  void _removeAttachment(String id) {
    setState(() {
      _attachments = _attachments
          .where((ChatAttachment item) => item.id != id)
          .toList(growable: false);
    });
  }

  Future<void> _send() async {
    final String typedContent = _composer.text.trim();
    final String content = typedContent.isNotEmpty
        ? typedContent
        : _attachments.isNotEmpty
        ? 'Review the attached file${_attachments.length == 1 ? '' : 's'}.'
        : '';
    if (!widget.isComposerEnabled || content.isEmpty) return;
    if (_isSending) {
      // The agent is still working: guide the running turn instead of waiting.
      if (typedContent.isEmpty) return;
      final bool accepted = widget.provider.sendSteeringMessage(
        content,
        onError: (Object error) {
          if (mounted) _showErrorToast(context, "Couldn't send the message: $error");
        },
      );
      if (accepted) {
        _clearComposerContext();
        if (mounted) {
          setState(() {
            _fileSuggestions = const <WorkspaceFileMatch>[];
            _tagQuery = null;
          });
        }
        _scheduleScrollToBottom();
      }
      return;
    }
    final ChatFileContext fileContext = ChatFileContext(
      activeFile: widget.activeFile,
      taggedFiles: _activeComposerReferences,
      attachments: List<ChatAttachment>.unmodifiable(_attachments),
    );
    setState(() => _isStarting = true);
    try {
      EngineLlmProvider provider = widget.provider;
      if (widget.thread == null) {
        final MaterializeThreadDraftCallback? materialize =
            widget.onMaterializeThreadDraft;
        if (materialize == null) {
          throw StateError('The draft thread cannot be created.');
        }
        final String? chosenExecutor = widget.provider.executorNodeId;
        provider = await materialize(content);
        // The draft's choice follows the new thread and is stored for it.
        if (chosenExecutor != null && !identical(provider, widget.provider)) {
          provider.selectExecutor(chosenExecutor);
          final String? created = provider.threadUuid;
          if (created != null) {
            unawaited(widget.executors?.saveSelection(created, chosenExecutor));
          }
        }
        if (widget.executors case final ExecutorDirectory directory) {
          provider.nodeNameOf = directory.nameOf;
        }
      }
      _clearComposerContext();
      if (mounted) {
        setState(() {
          _attachments = const <ChatAttachment>[];
          _fileSuggestions = const <WorkspaceFileMatch>[];
          _tagQuery = null;
        });
      }
      final Future<void> turn = provider.runTurn(
        content,
        fileContext: fileContext,
      );
      if (mounted) setState(() => _isStarting = false);
      final Future<void> Function()? refreshActiveFile =
          widget.onRefreshActiveFile;
      // Do not hold the composer: the turn keeps running even if this panel
      // is replaced by another thread.
      unawaited(
        turn.then<void>(
          (_) async {
            if (fileContext.activeFile != null && refreshActiveFile != null) {
              try {
                await refreshActiveFile();
              } on Object {
                // A successful turn should not fail because a preview refresh did.
              }
            }
          },
          onError: (Object error) {
            if (mounted) {
              _showErrorToast(context, "Couldn't send the message: $error");
            }
          },
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        _showErrorToast(context, "Couldn't send the message: $error");
      }
    } finally {
      if (mounted) setState(() => _isStarting = false);
      _scheduleScrollToBottom();
    }
  }

  bool get _isSending => _isStarting || widget.provider.isBusy;

  void _stopTurn() => unawaited(widget.provider.cancelTurn());

  void _createThread() {
    if (_showThreadSettings) setState(() => _showThreadSettings = false);
    widget.onCreateThread?.call();
  }

  void _toggleThreadSettings() {
    setState(() => _showThreadSettings = !_showThreadSettings);
  }

  Future<void> _saveThreadSettings(_ThreadSettingsDraft draft) async {
    final ThreadInfo? thread = widget.thread;
    if (thread == null) {
      final UpdateThreadDraftCallback? updateDraft = widget.onUpdateThreadDraft;
      if (updateDraft == null) return;
      updateDraft(title: draft.title, toolsConfig: draft.toolsConfig);
    } else {
      final UpdateThreadCallback? update = widget.onUpdateThread;
      if (update == null) return;
      await update(
        thread: thread,
        title: draft.title,
        toolsConfig: draft.toolsConfig,
        clearToolsConfig: draft.useWorkspaceDefaults,
      );
    }
    if (mounted) setState(() => _showThreadSettings = false);
  }

  @override
  void dispose() {
    _modelLoadVersion++;
    _modelUpdateVersion++;
    _workspaceDefaultLoadVersion++;
    _tagSearchVersion++;
    _tagSearchDebounce?.cancel();
    widget.provider.removeListener(_onProviderChanged);
    _voice
      ..removeListener(_onVoiceChanged)
      ..dispose();
    _composer
      ..removeListener(_onComposerChanged)
      ..dispose();
    _composerFocusNode.dispose();
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
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double horizontalPadding = constraints.maxWidth > 770
              ? (constraints.maxWidth - 750) / 2
              : 10;
          Widget gutter(Widget child) => Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: child,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              gutter(
                _ChatHeader(
                  title: widget.title?.trim().isNotEmpty ?? false
                      ? widget.title!
                      : 'New thread',
                  canCreateThread:
                      widget.isComposerEnabled &&
                      widget.onCreateThread != null,
                  canEditThread:
                      (widget.isComposerEnabled || _showThreadSettings) &&
                      !_isSending &&
                      widget.workspace != null &&
                      (widget.thread == null
                          ? widget.onUpdateThreadDraft != null
                          : widget.onUpdateThread != null),
                  settingsVisible: _showThreadSettings,
                  onCreateThread: _createThread,
                  onEditThread: _toggleThreadSettings,
                ),
              ),
              Expanded(
                child: _showThreadSettings && widget.workspace != null
                    ? gutter(
                        _ThreadSettingsPanel(
                          repository: widget.provider.repository,
                          workspace: widget.workspace!,
                          initialTitle: widget.title,
                          initialToolsConfig:
                              widget.thread?.toolsConfig ??
                              widget.draftToolsConfig,
                          threadUuid: widget.thread?.uuid,
                          isDraft: widget.thread == null,
                          onCancel: _toggleThreadSettings,
                          onSave: _saveThreadSettings,
                        ),
                      )
                    : messages.isEmpty
                    ? const _EmptyChat()
                    : Scrollbar(
                        controller: _scrollController,
                        child: SelectionArea(child: ListView.builder(
                            controller: _scrollController,
                          padding: EdgeInsets.fromLTRB(
                            horizontalPadding + 14,
                            14,
                            horizontalPadding + 14,
                            10,
                          ),
                          itemCount: messages.length,
                          itemBuilder: (BuildContext context, int index) =>
                              _MessageBubble(
                                message: messages[index],
                                timestamp: widget.provider.timestampFor(
                                  messages[index],
                                ),
                                useNeutralUserBubbleForeground:
                                    widget.useNeutralUserBubbleForeground,
                                onSpeak:
                                    _voice.canSpeak &&
                                        messages[index].origin ==
                                            EngineChatMessageOrigin.assistant
                                    ? () => unawaited(
                                        _voice.toggleSpeak(
                                          messages[index],
                                          messages[index].text,
                                        ),
                                      )
                                    : null,
                                isSpeaking:
                                    _voice.speakingKey == messages[index],
                              ),
                        )),
                      ),
              ),
              if (!_showThreadSettings)
                if (widget.toolApproval case final ToolApprovalRequest request)
                  gutter(
                    _ToolApprovalCard(
                      request: request,
                      onDecision: widget.onToolApproval,
                    ),
                  ),
              if (!_showThreadSettings && widget.executors != null)
                gutter(TaskStatusBar(provider: widget.provider)),
              if (!_showThreadSettings && _voice.realtime != RealtimeState.off)
                gutter(_VoiceBanner(voice: _voice, onEnd: _toggleRealtime)),
              if (!_showThreadSettings)
                gutter(
                  _Composer(
                    controller: _composer,
                    focusNode: _composerFocusNode,
                    models: _models
                        .where((ModelInfo model) => model.isChatModel)
                        .toList(growable: false),
                    selectedModelId: widget.provider.modelId,
                    workspaceDefaultModelId: _workspaceDefaultModelId,
                    activeFile: widget.activeFile,
                    fileSuggestions: _fileSuggestions,
                    attachments: _attachments,
                    isSending: _isSending,
                    isModelUpdating: _isUpdatingModel,
                    enabled: widget.isComposerEnabled,
                    onFileSelected: _selectTaggedFile,
                    onAddAttachment: () => unawaited(_pickAttachments()),
                    onRemoveAttachment: _removeAttachment,
                    executorPicker: widget.executors == null
                        ? null
                        : ExecutorPicker(
                            provider: widget.provider,
                            directory: widget.executors!,
                            onSelected: _selectExecutor,
                            enabled: widget.isComposerEnabled && !_isSending,
                          ),
                    onModelSelected: (String modelId) =>
                        unawaited(_selectModel(modelId)),
                    onSend: _send,
                    onStop: _stopTurn,
                    voice: _voice,
                    onToggleDictation: () => unawaited(_toggleDictation()),
                    onToggleRealtime: () => unawaited(_toggleRealtime()),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

final class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.title,
    required this.canCreateThread,
    required this.canEditThread,
    required this.settingsVisible,
    required this.onCreateThread,
    required this.onEditThread,
  });

  final String title;
  final bool canCreateThread;
  final bool canEditThread;
  final bool settingsVisible;
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
          IconButton(
            tooltip: settingsVisible
                ? 'Close thread settings'
                : 'Thread settings',
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            padding: EdgeInsets.zero,
            isSelected: settingsVisible,
            style: IconButton.styleFrom(
              backgroundColor: settingsVisible
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
              foregroundColor: settingsVisible
                  ? Theme.of(context).colorScheme.onSecondaryContainer
                  : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            onPressed: canEditThread ? onEditThread : null,
            icon: const Icon(FluentIcons.more_horizontal_20_regular, size: 20),
          ),
        ],
      ),
    ),
  );
}

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
    this.onSpeak,
    this.isSpeaking = false,
  });

  /// Reads the message aloud; null when no text-to-speech model is set up.
  final VoidCallback? onSpeak;
  final bool isSpeaking;
  final EngineChatMessage message;
  final DateTime? timestamp;
  final bool useNeutralUserBubbleForeground;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool isUser = message.origin == EngineChatMessageOrigin.user;
    final bool isSystem = message.origin == EngineChatMessageOrigin.system;
    final bool isAssistant =
        message.origin == EngineChatMessageOrigin.assistant;
    final bool useNeutralForeground = isUser && useNeutralUserBubbleForeground;
    final Color? messageForeground = useNeutralForeground
        ? colors.onSecondaryContainer
        : null;
    final Color metadataForeground = useNeutralForeground
        ? colors.onSecondaryContainer.withValues(alpha: 0.7)
        : colors.onSurfaceVariant;
    final String text = message.text;
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (isAssistant)
          MarkdownPreview(text: text, embedded: true, debounce: Duration.zero)
        else
          Text.rich(
            _withReferencePills(
              context,
              text,
              Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(height: 1.45, color: messageForeground),
            ),
          ),
        Row(
          children: <Widget>[
            if (timestamp != null)
              Text(
                _formatTimestamp(timestamp!),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: metadataForeground),
              ),
            if (isAssistant && message.ranOn != null)
              NodeBadge(name: message.ranOn!),
            if (isAssistant && message.elapsed != null)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(
                  _formatElapsed(message.elapsed!),
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: metadataForeground),
                ),
              ),
            if (isAssistant && (message.tokens ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(
                  '${message.tokensEstimated ? '~' : ''}${message.tokens} tokens',
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: metadataForeground),
                ),
              ),
            const Spacer(),
            if (onSpeak != null)
              IconButton(
                tooltip: isSpeaking ? 'Stop reading' : 'Read aloud',
                constraints: const BoxConstraints.tightFor(width: 26, height: 26),
                padding: EdgeInsets.zero,
                style: _compactControlStyle(context),
                onPressed: onSpeak,
                icon: Icon(
                  isSpeaking
                      ? FluentIcons.stop_16_regular
                      : FluentIcons.speaker_2_16_regular,
                  size: 14,
                ),
              ),
            IconButton(
              tooltip: 'Copy message',
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              padding: EdgeInsets.zero,
              style: useNeutralForeground
                  ? IconButton.styleFrom(
                      foregroundColor: metadataForeground,
                      disabledForegroundColor: colors.onSecondaryContainer
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
    if (isSystem) {
      return Align(
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 5),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Notification',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              content,
            ],
          ),
        ),
      );
    }
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
            color: colors.secondaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: content,
        ),
      ),
    );
  }
}

final class _ToolApprovalCard extends StatelessWidget {
  const _ToolApprovalCard({required this.request, required this.onDecision});

  final ToolApprovalRequest request;
  final ValueChanged<bool>? onDecision;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (request.remote)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${request.peerName ?? 'Another device'} wants to use a tool '
                'on this device',
                key: const ValueKey<String>('remote-approval-peer'),
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: colors.onTertiaryContainer),
              ),
            ),
          Text(
            'Approval required: ${request.toolName}',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.onTertiaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${request.operation}: ${jsonEncode(request.arguments)}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onTertiaryContainer),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                onPressed: onDecision == null ? null : () => onDecision!(false),
                child: const Text('Deny'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onDecision == null ? null : () => onDecision!(true),
                child: const Text('Approve once'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.models,
    required this.selectedModelId,
    required this.workspaceDefaultModelId,
    required this.activeFile,
    required this.fileSuggestions,
    required this.attachments,
    required this.isSending,
    required this.isModelUpdating,
    required this.enabled,
    required this.onFileSelected,
    required this.onAddAttachment,
    required this.onRemoveAttachment,
    required this.onModelSelected,
    required this.onSend,
    required this.onStop,
    required this.voice,
    required this.onToggleDictation,
    required this.onToggleRealtime,
    this.executorPicker,
  });

  /// Optional "run on" control shown next to the send button.
  final Widget? executorPicker;

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<ModelInfo> models;
  final String? selectedModelId;
  final String? workspaceDefaultModelId;
  final ChatFileReference? activeFile;
  final List<WorkspaceFileMatch> fileSuggestions;
  final List<ChatAttachment> attachments;
  final bool isSending;
  final bool isModelUpdating;
  final bool enabled;
  final ValueChanged<WorkspaceFileMatch> onFileSelected;
  final VoidCallback onAddAttachment;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<String> onModelSelected;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoiceController voice;
  final VoidCallback onToggleDictation;
  final VoidCallback onToggleRealtime;

  @override
  Widget build(BuildContext context) {
    final String? defaultModelId =
        workspaceDefaultModelId?.trim().isNotEmpty ?? false
        ? workspaceDefaultModelId
        : null;
    final String? effectiveModelId = selectedModelId?.trim().isNotEmpty ?? false
        ? selectedModelId
        : defaultModelId;
    final bool hasSelectedModel = models.any(
      (ModelInfo model) => model.id == effectiveModelId,
    );
    final bool hasWorkspaceDefaultModel = models.any(
      (ModelInfo model) => model.id == defaultModelId,
    );
    final bool interactive = enabled && !isSending;
    final bool modelInteractive =
        interactive &&
        !isModelUpdating &&
        (models.isNotEmpty || effectiveModelId != null);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 10),
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
          if (fileSuggestions.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 168),
              child: Material(
                color: colors.surfaceContainerLow,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(6),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: fileSuggestions.length,
                  itemBuilder: (BuildContext context, int index) {
                    final WorkspaceFileMatch file = fileSuggestions[index];
                    final String path = file.relativePath.replaceAll('\\', '/');
                    final int slash = path.lastIndexOf('/');
                    final String name = path.substring(slash + 1);
                    final TextStyle? base = Theme.of(context)
                        .textTheme
                        .bodyMedium;
                    return InkWell(
                      onTap: () => onFileSelected(file),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        child: Row(
                          children: <Widget>[
                            const Icon(
                              FluentIcons.document_20_regular,
                              size: 17,
                            ),
                            const SizedBox(width: 10),
                            Text(name, style: base),
                            if (slash > 0) ...<Widget>[
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  path.substring(0, slash),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textDirection: TextDirection.rtl,
                                  style: base?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          if (activeFile != null || attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: <Widget>[
                  if (activeFile case final ChatFileReference file)
                    Tooltip(
                      message: file.label,
                      child: InputChip(
                        avatar: const Icon(
                          FluentIcons.edit_20_regular,
                          size: 13,
                        ),
                        label: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            'Active: ${file.label}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                        visualDensity: const VisualDensity(
                          horizontal: -2,
                          vertical: -4,
                        ),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 3),
                        onPressed: null,
                      ),
                    ),
                  for (final ChatAttachment attachment in attachments)
                    InputChip(
                      avatar: const Icon(
                        FluentIcons.attach_20_regular,
                        size: 13,
                      ),
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          attachment.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      tooltip: attachment.name,
                      visualDensity: const VisualDensity(
                        horizontal: -2,
                        vertical: -4,
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 3),
                      onDeleted: interactive
                          ? () => onRemoveAttachment(attachment.id)
                          : null,
                    ),
                ],
              ),
            ),
          TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            minLines: 3,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              hintText: enabled ? 'Ask anything…' : 'Engine unavailable',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              hintStyle: TextStyle(
                color: colors.onSurfaceVariant.withValues(alpha: 0.33),
              ),
              contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: 'Attach files',
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: interactive && attachments.length < 5
                      ? onAddAttachment
                      : null,
                  style: _compactControlStyle(context),
                  icon: const Icon(FluentIcons.attach_20_regular, size: 19),
                ),
                if (voice.canDictate) ...<Widget>[
                  const SizedBox(width: 2),
                  _DictationButton(
                    state: voice.dictation,
                    enabled: enabled && voice.realtime == RealtimeState.off,
                    onPressed: onToggleDictation,
                  ),
                ],
                if (voice.canRealtime) ...<Widget>[
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: voice.realtime == RealtimeState.off
                        ? 'Talk (realtime voice)'
                        : 'End voice conversation',
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    padding: EdgeInsets.zero,
                    isSelected: voice.realtime != RealtimeState.off,
                    style: _compactControlStyle(context),
                    onPressed: enabled ? onToggleRealtime : null,
                    icon: const Icon(
                      FluentIcons.headphones_sound_wave_20_regular,
                      size: 19,
                    ),
                  ),
                ],
                const SizedBox(width: 6),
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
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.normal),
                          focusColor: colors.secondaryContainer,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          value: effectiveModelId,
                          hint: Text(
                            models.isEmpty
                                ? 'No models available'
                                : 'Select a model',
                            overflow: TextOverflow.ellipsis,
                          ),
                          items: <DropdownMenuItem<String>>[
                            if (effectiveModelId != null && !hasSelectedModel)
                              DropdownMenuItem<String>(
                                value: effectiveModelId,
                                child: _modelDropdownLabel(
                                  context,
                                  effectiveModelId,
                                  isDefault: effectiveModelId == defaultModelId,
                                ),
                              ),
                            if (defaultModelId != null &&
                                defaultModelId != effectiveModelId &&
                                !hasWorkspaceDefaultModel)
                              DropdownMenuItem<String>(
                                value: defaultModelId,
                                child: _modelDropdownLabel(
                                  context,
                                  defaultModelId,
                                  isDefault: true,
                                ),
                              ),
                            for (final ModelInfo model in models)
                              DropdownMenuItem<String>(
                                value: model.id,
                                child: _modelDropdownLabel(
                                  context,
                                  model.name,
                                  isDefault: model.id == defaultModelId,
                                ),
                              ),
                          ],
                          onChanged: modelInteractive
                              ? (String? value) {
                                  if (value != null) onModelSelected(value);
                                }
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (executorPicker case final Widget picker) ...<Widget>[
                  SizedBox.square(dimension: 32, child: picker),
                  const SizedBox(width: 4),
                ],
                IconButton(
                  tooltip: !enabled
                      ? 'Engine unavailable'
                      : isSending
                      ? 'Send to the running agent'
                      : 'Send',
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: enabled ? onSend : null,
                  style: _compactControlStyle(context),
                  icon: const Icon(FluentIcons.send_20_regular, size: 20),
                ),
                if (isSending) ...<Widget>[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Stop',
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: onStop,
                    style: _compactControlStyle(context),
                    icon: const Icon(FluentIcons.stop_20_regular, size: 20),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _DictationButton extends StatelessWidget {
  const _DictationButton({
    required this.state,
    required this.enabled,
    required this.onPressed,
  });

  final DictationState state;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return switch (state) {
      DictationState.transcribing => const SizedBox.square(
        dimension: 32,
        child: Padding(
          padding: EdgeInsets.all(8),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      DictationState.recording => IconButton(
        tooltip: 'Stop recording',
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          foregroundColor: colors.onError,
          backgroundColor: colors.error,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        onPressed: onPressed,
        icon: const Icon(FluentIcons.stop_20_filled, size: 18),
      ),
      DictationState.idle => IconButton(
        tooltip: 'Dictate a message',
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        style: _compactControlStyle(context),
        onPressed: enabled ? onPressed : null,
        icon: const Icon(FluentIcons.mic_20_regular, size: 19),
      ),
    };
  }
}

/// Live caption and controls while a realtime voice conversation is open.
final class _VoiceBanner extends StatelessWidget {
  const _VoiceBanner({required this.voice, required this.onEnd});

  final VoiceController voice;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final VoiceLine? last = voice.lines.isEmpty ? null : voice.lines.last;
    final String status = voice.realtime == RealtimeState.connecting
        ? 'Connecting…'
        : voice.toolActivity != null
        ? 'Working on it…'
        : 'Listening';
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: colors.secondaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              FluentIcons.headphones_sound_wave_20_regular,
              size: 18,
              color: colors.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    status,
                    style: text.labelMedium?.copyWith(
                      color: colors.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (last != null)
                    Text(
                      '${last.role == 'user' ? 'You' : 'Assistant'}: ${last.text}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                ],
              ),
            ),
            TextButton(onPressed: onEnd, child: const Text('End')),
          ],
        ),
      ),
    );
  }
}

final class _TagQuery {
  const _TagQuery(this.query, this.start, this.end);

  final String query;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is _TagQuery &&
      other.query == query &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(query, start, end);
}

final class _ComposerTextController extends TextEditingController {
  final Map<String, ChatFileReference> _referencesByToken =
      <String, ChatFileReference>{};

  List<ChatFileReference> get activeReferences {
    final Set<String> seen = <String>{};
    return <ChatFileReference>[
      for (final MapEntry<String, ChatFileReference> entry
          in _referencesByToken.entries)
        if (text.contains(entry.key) &&
            seen.add('${entry.value.rootIndex}:${entry.value.path}'))
          entry.value,
    ];
  }

  void insertFileTag(WorkspaceFileMatch match, _TagQuery query) {
    String token = '#${match.relativePath}';
    final ChatFileReference? collision = _referencesByToken[token];
    if (collision != null &&
        (collision.rootIndex != match.rootIndex ||
            collision.path != match.relativePath)) {
      token = '$token [folder ${match.rootIndex + 1}]';
    }
    _referencesByToken[token] = ChatFileReference(
      rootIndex: match.rootIndex,
      path: match.relativePath,
      label: match.relativePath,
    );
    final String next = text.replaceRange(query.start, query.end, '$token ');
    value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: query.start + token.length + 1,
      ),
    );
  }

  void clearContext() {
    _referencesByToken.clear();
    clear();
  }

  static _TagQuery? currentTagQuery(TextEditingValue value) {
    final TextSelection selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final int cursor = selection.extentOffset;
    if (cursor < 0 || cursor > value.text.length) return null;
    final String prefix = value.text.substring(0, cursor);
    final int hash = prefix.lastIndexOf('#');
    if (hash < 0) return null;
    if (hash > 0 && !RegExp(r'\s').hasMatch(prefix[hash - 1])) return null;
    final String query = prefix.substring(hash + 1);
    if (RegExp(r'[\s#]').hasMatch(query)) return null;
    return _TagQuery(query, hash, cursor);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final List<String> tokens =
        _referencesByToken.keys.where(text.contains).toList(growable: false)
          ..sort(
            (String left, String right) => right.length.compareTo(left.length),
          );
    if (tokens.isEmpty) return TextSpan(style: style, text: text);
    final List<InlineSpan> spans = <InlineSpan>[];
    int cursor = 0;
    while (cursor < text.length) {
      String? nearestToken;
      int nearestIndex = text.length;
      for (final String token in tokens) {
        final int index = text.indexOf(token, cursor);
        if (index >= 0 && index < nearestIndex) {
          nearestIndex = index;
          nearestToken = token;
        }
      }
      if (nearestToken == null) {
        spans.add(TextSpan(text: text.substring(cursor)));
        break;
      }
      if (nearestIndex > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, nearestIndex)));
      }
      spans.add(
        TextSpan(
          text: nearestToken,
          style: style?.copyWith(
            color: Theme.of(context).colorScheme.onSecondaryContainer,
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      cursor = nearestIndex + nearestToken.length;
    }
    return TextSpan(style: style, children: spans);
  }
}

String _attachmentMediaType(String name) {
  final String lower = name.toLowerCase();
  if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
    return 'text/markdown';
  }
  if (lower.endsWith('.txt') ||
      lower.endsWith('.dart') ||
      lower.endsWith('.py') ||
      lower.endsWith('.js') ||
      lower.endsWith('.ts') ||
      lower.endsWith('.java') ||
      lower.endsWith('.cs') ||
      lower.endsWith('.cpp') ||
      lower.endsWith('.yml') ||
      lower.endsWith('.yaml') ||
      lower.endsWith('.toml')) {
    return 'text/plain';
  }
  if (lower.endsWith('.json')) return 'application/json';
  if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
  if (lower.endsWith('.csv')) return 'text/csv';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.docx')) {
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  }
  if (lower.endsWith('.xlsx')) {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.wav')) return 'audio/wav';
  return 'application/octet-stream';
}

String? _normalizedModelId(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Widget _modelDropdownLabel(
  BuildContext context,
  String name, {
  required bool isDefault,
}) => Text.rich(
  TextSpan(
    text: name,
    children: <InlineSpan>[
      if (isDefault)
        TextSpan(
          text: ' (default)',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
    ],
  ),
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
);

String _formatElapsed(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
  if (d.inSeconds < 60)
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
  return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
}

/// Renders #path references as rounded pills like attachment chips.
TextSpan _withReferencePills(
  BuildContext context,
  String text,
  TextStyle? style,
) {
  final ColorScheme colors = Theme.of(context).colorScheme;
  final RegExp pattern = RegExp(r'(?<=^|\s)#[^\s#]+');
  final List<InlineSpan> spans = <InlineSpan>[];
  int cursor = 0;
  for (final RegExpMatch m in pattern.allMatches(text)) {
    if (m.start > cursor)
      spans.add(TextSpan(text: text.substring(cursor, m.start)));
    final String label = m.group(0)!.substring(1);
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(FluentIcons.document_20_regular, size: 13),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: style?.copyWith(fontSize: (style.fontSize ?? 14) - 1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    cursor = m.end;
  }
  if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
  return TextSpan(style: style, children: spans);
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

EdgeInsets _panelToastMargin(BuildContext context) {
  const double inset = 12;
  final Size viewport = MediaQuery.sizeOf(context);
  final RenderObject? renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return const EdgeInsets.all(inset);
  }
  final Offset origin = renderObject.localToGlobal(Offset.zero);
  final double left = (origin.dx + inset)
      .clamp(inset, viewport.width - inset)
      .toDouble();
  final double right =
      (viewport.width - origin.dx - renderObject.size.width + inset)
          .clamp(inset, viewport.width - inset)
          .toDouble();
  if (left + right >= viewport.width) {
    return const EdgeInsets.all(inset);
  }
  return EdgeInsets.fromLTRB(left, inset, right, inset);
}

void _showErrorToast(BuildContext context, String message) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final ColorScheme colors = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colors.onErrorContainer),
        ),
        behavior: SnackBarBehavior.floating,
        margin: _panelToastMargin(context),
        duration: const Duration(seconds: 5),
        showCloseIcon: true,
        backgroundColor: colors.errorContainer,
        closeIconColor: colors.onErrorContainer,
      ),
    );
}

ButtonStyle _compactControlStyle(BuildContext context) => IconButton.styleFrom(
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
);

IconButton _compactIconButton({
  required String tooltip,
  required VoidCallback? onPressed,
  required Widget icon,
}) => IconButton(
  tooltip: tooltip,
  constraints: const BoxConstraints.tightFor(width: 32, height: 32),
  padding: EdgeInsets.zero,
  style: IconButton.styleFrom(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
  ),
  onPressed: onPressed,
  icon: icon,
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

typedef _SaveThreadSettingsCallback = Future<void> Function(
  _ThreadSettingsDraft draft,
);

final class _ThreadSettingsPanel extends StatefulWidget {
  const _ThreadSettingsPanel({
    required this.repository,
    required this.workspace,
    required this.initialTitle,
    required this.initialToolsConfig,
    required this.threadUuid,
    required this.isDraft,
    required this.onCancel,
    required this.onSave,
  });

  final EngineRepository repository;
  final Workspace workspace;
  final String? initialTitle;
  final String? initialToolsConfig;
  final String? threadUuid;
  final bool isDraft;
  final VoidCallback onCancel;
  final _SaveThreadSettingsCallback onSave;

  @override
  State<_ThreadSettingsPanel> createState() => _ThreadSettingsPanelState();
}

final class _ThreadSettingsPanelState extends State<_ThreadSettingsPanel> {
  late final TextEditingController _titleController;
  ToolCatalog? _catalog;
  Map<String, dynamic> _rawTools = <String, dynamic>{};
  Map<String, bool> _builtinGroups = <String, bool>{};
  Map<String, Map<String, bool>> _builtinTools = <String, Map<String, bool>>{};
  Map<String, bool> _configuredTools = <String, bool>{};
  bool _useWorkspaceDefaults = true;
  bool _builtinEnabled = true;
  bool _configuredEnabled = true;
  bool _builtinExpanded = true;
  bool _configuredExpanded = false;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle ?? '');
    _useWorkspaceDefaults = widget.initialToolsConfig == null;
    unawaited(_loadCatalog());
  }

  Future<void> _loadCatalog() async {
    try {
      final ToolCatalog catalog = await widget.repository.rest
          .listToolCatalog();
      final Map<String, dynamic> config = _decodeConfig(
        widget.initialToolsConfig ?? widget.workspace.toolsConfig,
      );
      final Map<String, dynamic> builtin = _objectValue(config['builtin']);
      final Map<String, bool> builtinGroups = <String, bool>{};
      final Map<String, Map<String, bool>> builtinTools =
          <String, Map<String, bool>>{};
      for (final MapEntry<String, List<BuiltinToolCatalogEntry>> group
          in catalog.builtin.entries) {
        final Map<String, dynamic> groupConfig = _objectValue(
          builtin[group.key],
        );
        final Map<String, dynamic> tools = _objectValue(groupConfig['tools']);
        builtinGroups[group.key] = _readBool(
          groupConfig,
          'enabled',
          fallback: true,
        );
        builtinTools[group.key] = <String, bool>{
          for (final BuiltinToolCatalogEntry tool in group.value)
            tool.name: _readBool(tools, tool.name, fallback: true),
        };
      }
      final Map<String, dynamic> configured = _objectValue(
        config['configured'],
      );
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _rawTools = config;
        _builtinEnabled = _readBool(config, 'builtin_enabled', fallback: true);
        _configuredEnabled = _readBool(
          config,
          'configured_enabled',
          fallback: true,
        );
        _builtinGroups = builtinGroups;
        _builtinTools = builtinTools;
        _configuredTools = <String, bool>{
          for (final ToolRegistryEntry tool in catalog.configured)
            tool.uuid: _readBool(configured, tool.uuid, fallback: true),
        };
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showErrorToast(context, "Couldn't load thread tools: $error");
    }
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

  Future<void> _submit() async {
    if (_loading || _saving) return;
    final String title = _titleController.text.trim();
    setState(() => _saving = true);
    try {
      await widget.onSave(
        _ThreadSettingsDraft(
          title: title.isEmpty ? null : title,
          toolsConfig: _useWorkspaceDefaults ? null : _serializeTools(),
          useWorkspaceDefaults: _useWorkspaceDefaults,
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        _showErrorToast(context, "Couldn't save thread settings: $error");
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Widget title = Text(
              'Edit Thread',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontSize: 18, fontWeight: FontWeight.bold),
            );
            final Widget actions = Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _compactIconButton(
                  tooltip: 'Cancel thread settings',
                  onPressed: _saving ? null : widget.onCancel,
                  icon: const Icon(FluentIcons.dismiss_20_regular, size: 18),
                ),
                _compactIconButton(
                  tooltip: 'Save thread settings',
                  onPressed: _loading || _saving ? null : _submit,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(FluentIcons.save_20_regular, size: 18),
                ),
              ],
            );
            if (constraints.maxWidth >= 255) {
              return Row(children: <Widget>[title, const Spacer(), actions]);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Align(alignment: Alignment.centerLeft, child: title),
                const SizedBox(height: 8),
                actions,
              ],
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 6, top: 18),
          child: Text(
            'Thread name',
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        TextField(
          controller: _titleController,
          autofocus: widget.isDraft,
          enabled: !_saving,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'New thread',
            filled: true,
            fillColor: colors.surfaceContainerLowest,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
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
            hintStyle: TextStyle(
              color: colors.onSurfaceVariant.withValues(alpha: 0.33),
            ),
          ),
        ),
        if (widget.threadUuid case final String threadUuid) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 18),
            child: Text(
              'Thread UUID',
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: Theme(
                    data: settingsFormTheme(context),
                    child: TextFormField(
                      key: ValueKey<String>(threadUuid),
                      initialValue: threadUuid,
                      readOnly: true,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.center,
                      decoration: const InputDecoration(
                        constraints: BoxConstraints.tightFor(height: 32),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                dimension: 32,
                child: IconButton(
                  tooltip: 'Copy thread UUID',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: colors.surfaceContainerLowest,
                    side: BorderSide(color: colors.outlineVariant),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(3)),
                    ),
                  ),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: threadUuid));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Thread UUID copied')),
                      );
                    }
                  },
                  icon: const Icon(FluentIcons.copy_20_regular, size: 17),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        _switchRow(
          context,
          title: 'Use workspace defaults',
          subtitle:
              'Inherit the tool policy configured for ${widget.workspace.name}.',
          value: _useWorkspaceDefaults,
          onChanged: _loading || _saving
              ? null
              : (bool value) => setState(() => _useWorkspaceDefaults = value),
        ),
        const SizedBox(height: 10),
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        _buildBuiltinTools(context),
        const SizedBox(height: 10),
        _buildConfiguredTools(context),
      ],
    );
  }

  Widget _switchRow(
    BuildContext context, {
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
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
          onChanged: onChanged,
          semanticLabel: title,
        ),
      ],
    ),
  );

  Widget _toolCardHeader(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    required String semanticLabel,
    required bool expanded,
    required VoidCallback onToggle,
  }) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final Widget controls = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _RectangularSwitch(
            value: value,
            onChanged: onChanged,
            semanticLabel: semanticLabel,
          ),
          const SizedBox(width: 8),
          Icon(
            expanded
                ? FluentIcons.chevron_up_20_regular
                : FluentIcons.chevron_down_20_regular,
            size: 17,
          ),
        ],
      );
      if (constraints.maxWidth >= 220) {
        return ListTile(
          onTap: onToggle,
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: controls,
        );
      }
      return InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              Align(alignment: Alignment.centerRight, child: controls),
            ],
          ),
        ),
      );
    },
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
        _toolCardHeader(
          context,
          title: 'Builtin Tools',
          subtitle: 'Enable tools provided by the engine.',
          value: _builtinEnabled,
          onChanged: _toolsEditable
              ? (bool value) => _change(() => _builtinEnabled = value)
              : null,
          semanticLabel: 'Enable built-in tools',
          expanded: _builtinExpanded,
          onToggle: () => setState(() => _builtinExpanded = !_builtinExpanded),
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
                    if (_catalog?.builtin.isEmpty ?? true)
                      const ListTile(
                        title: Text('No built-in tools are available.'),
                      ),
                    for (final MapEntry<String, List<BuiltinToolCatalogEntry>>
                        group
                        in _catalog?.builtin.entries ??
                            const <String, List<BuiltinToolCatalogEntry>>{}
                                .entries)
                      ExpansionTile(
                        title: Text(_displayName(group.key)),
                        trailing: _RectangularSwitch(
                          value: _builtinGroups[group.key] ?? true,
                          onChanged: _toolsEditable && _builtinEnabled
                              ? (bool value) => _change(
                                  () => _builtinGroups[group.key] = value,
                                )
                              : null,
                          semanticLabel:
                              'Enable ${_displayName(group.key)} tools',
                        ),
                        children: <Widget>[
                          for (final BuiltinToolCatalogEntry tool
                              in group.value)
                            _buildBuiltinToolRow(group.key, tool),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    ),
  );

  Widget _buildBuiltinToolRow(String group, BuiltinToolCatalogEntry tool) {
    final bool value = _builtinTools[group]?[tool.name] ?? true;
    final bool enabled =
        _toolsEditable && _builtinEnabled && (_builtinGroups[group] ?? true);
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
        _toolCardHeader(
          context,
          title: 'Custom Tools',
          subtitle:
              'Configured tools are addressed by their stable registry ID.',
          value: _configuredEnabled,
          onChanged: _toolsEditable
              ? (bool value) => _change(() => _configuredEnabled = value)
              : null,
          semanticLabel: 'Enable custom tools',
          expanded: _configuredExpanded,
          onToggle: () =>
              setState(() => _configuredExpanded = !_configuredExpanded),
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
                    if (_catalog?.configured.isEmpty ?? true)
                      const ListTile(
                        title: Text('No custom tools are configured.'),
                      ),
                    for (final ToolRegistryEntry tool
                        in _catalog?.configured ?? const <ToolRegistryEntry>[])
                      _buildConfiguredToolRow(tool),
                  ],
                ),
        ),
      ],
    ),
  );

  Widget _buildConfiguredToolRow(ToolRegistryEntry tool) {
    final bool value = _configuredTools[tool.uuid] ?? true;
    final bool enabled = _toolsEditable && _configuredEnabled;
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

  bool get _toolsEditable => !_useWorkspaceDefaults && !_loading && !_saving;

  void _change(VoidCallback update) => setState(update);

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

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> value) =>
      _objectValue(jsonDecode(jsonEncode(value)));

  static bool _readBool(
    Map<String, dynamic> value,
    String key, {
    required bool fallback,
  }) => value[key] is bool ? value[key] as bool : fallback;

  static String _displayName(String value) => value
      .split(RegExp('[_\\-\\s]+'))
      .where((String part) => part.isNotEmpty)
      .map(
        (String part) =>
            '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
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
