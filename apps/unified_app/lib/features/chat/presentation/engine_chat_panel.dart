import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../../editor/presentation/markdown/markdown_preview.dart';
import '../../editor/presentation/markdown/streaming_markdown.dart';
import '../../hive/executor_selection.dart';
import '../../tools/presentation/tool_policy_list.dart';
import '../../voice/voice_controller.dart';
import '../engine_llm_provider.dart';
import 'executor_widgets.dart';
import 'tool_activity_tile.dart';

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

/// A user-facing sentence for a chat failure: drops the `Bad state: ` /
/// `Exception: ` prefixes Dart adds to [StateError] / [Exception] strings.
String describeChatError(Object error) {
  final String text = error is StateError ? error.message.toString() : '$error';
  return text
      .replaceFirst(RegExp(r'^(Bad state|Exception|Error): '), '')
      .trim();
}

final class EngineChatPanel extends StatefulWidget {
  const EngineChatPanel({
    required this.provider,
    required this.isComposerEnabled,
    this.borderlessComposer = false,
    this.minTouchTarget,
    this.onOpenDevices,
    this.errorMessage,
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
    this.oauth,
    this.onOAuthOpen,
    this.onOAuthPaste,
    this.onOAuthCancel,
    this.oauthError,
    this.title,
    this.draftToolsConfig,
    this.executors,
    this.greetingName,
    this.threadsList,
    this.threadsListVisible = false,
    this.onToggleThreadsList,
    super.key,
  });

  /// The thread list. While [threadsListVisible] it takes the place of the
  /// conversation; null hides the header's threads button.
  final Widget? threadsList;
  final bool threadsListVisible;
  final VoidCallback? onToggleThreadsList;

  /// Who the empty thread greets by name; null shows a plain prompt.
  final String? greetingName;

  /// Where tasks can run. When null (no hive) the picker is not shown.
  final ExecutorDirectory? executors;
  final EngineLlmProvider provider;
  final bool isComposerEnabled;

  /// Mobile layout: the composer has no outline.
  final bool borderlessComposer;

  /// Raises the tappable size of the panel's icon buttons (mobile passes 48).
  final double? minTouchTarget;

  /// When set and the composer is disabled, a notice offers this shortcut to
  /// the Account/Devices page.
  final VoidCallback? onOpenDevices;

  /// A load/connection failure shown in a popup above the composer. The
  /// composer itself stays on screen and never gives way to an error.
  final Object? errorMessage;
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

  /// A tool sign-in waiting on the user, shown above any approval card.
  final OAuthAuthorization? oauth;
  final VoidCallback? onOAuthOpen;
  final ValueChanged<String>? onOAuthPaste;
  final VoidCallback? onOAuthCancel;
  final String? oauthError;
  final String? title;
  final String? draftToolsConfig;

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
    _voice = VoiceController(repository: () => widget.provider.engine)
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
        if (mounted)
          _showErrorToast(context, "Couldn't send the message: $missed");
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
      final List<ModelInfo> loaded = await widget.provider.engine.listModels();
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
      final Workspace refreshed = await widget.provider.engine.rest
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
      final List<WorkspaceFileMatch> matches = await widget.provider.engine.rest
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
          if (mounted)
            _showErrorToast(context, "Couldn't send the message: $error");
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
    // The thread list and the settings share the space of the conversation.
    if (!_showThreadSettings && widget.threadsListVisible) {
      widget.onToggleThreadsList?.call();
    }
    setState(() => _showThreadSettings = !_showThreadSettings);
  }

  void _toggleThreadsList() {
    if (!widget.threadsListVisible && _showThreadSettings) {
      setState(() => _showThreadSettings = false);
    }
    widget.onToggleThreadsList?.call();
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
          final bool showThreads =
              widget.threadsListVisible && widget.threadsList != null;
          final bool showSettings = _showThreadSettings && !showThreads;
          // Either one replaces the conversation and its composer.
          final bool overlay = showThreads || showSettings;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              gutter(
                _ChatHeader(
                  minTouchTarget: widget.minTouchTarget,
                  title: widget.title?.trim().isNotEmpty ?? false
                      ? widget.title!
                      : 'New thread',
                  canCreateThread:
                      widget.isComposerEnabled && widget.onCreateThread != null,
                  canEditThread:
                      (widget.isComposerEnabled || showSettings) &&
                      !_isSending &&
                      widget.workspace != null &&
                      (widget.thread == null
                          ? widget.onUpdateThreadDraft != null
                          : widget.onUpdateThread != null),
                  settingsVisible: showSettings,
                  onCreateThread: _createThread,
                  onEditThread: _toggleThreadSettings,
                  threadsVisible: showThreads,
                  onToggleThreads: widget.threadsList == null
                      ? null
                      : _toggleThreadsList,
                ),
              ),
              Expanded(
                child: showThreads
                    ? gutter(widget.threadsList!)
                    : showSettings &&
                        widget.workspace != null &&
                        widget.provider.repository != null
                    ? gutter(
                        _ThreadSettingsPanel(
                          repository: widget.provider.repository!,
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
                    ? _EmptyChat(name: widget.greetingName)
                    : Scrollbar(
                        controller: _scrollController,
                        child: SelectionArea(
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: EdgeInsets.fromLTRB(
                              horizontalPadding + 14,
                              14,
                              horizontalPadding + 14,
                              10,
                            ),
                            itemCount: messages.length,
                            itemBuilder: (BuildContext context, int index) {
                              final EngineChatMessage message = messages[index];
                              final ToolCallInfo? toolCall = message.toolCall;
                              if (toolCall != null) {
                                // Tool calls, approvals and sub-agent work are
                                // records, not replies: a collapsed card.
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: ToolActivityTile(call: toolCall),
                                );
                              }
                              return _MessageBubble(
                                message: message,
                                timestamp: widget.provider.timestampFor(
                                  message,
                                ),
                                minTouchTarget: widget.minTouchTarget,
                                onSpeak:
                                    _voice.canSpeak &&
                                        message.origin ==
                                            EngineChatMessageOrigin.assistant
                                    ? () => unawaited(
                                        _voice.toggleSpeak(
                                          message,
                                          message.text,
                                        ),
                                      )
                                    : null,
                                isSpeaking: _voice.speakingKey == message,
                                streaming: widget.provider.isStreaming(message),
                              );
                            },
                          ),
                        ),
                      ),
              ),
              if (!overlay)
                if (widget.oauth case final OAuthAuthorization authorization)
                  gutter(
                    _OAuthSignInCard(
                      authorization: authorization,
                      onOpen: widget.onOAuthOpen,
                      onPaste: widget.onOAuthPaste,
                      onCancel: widget.onOAuthCancel,
                      error: widget.oauthError,
                    ),
                  ),
              if (!overlay)
                if (widget.toolApproval case final ToolApprovalRequest request)
                  gutter(
                    _ToolApprovalCard(
                      request: request,
                      onDecision: widget.onToolApproval,
                    ),
                  ),
              if (!overlay &&
                  (widget.errorMessage != null ||
                      (!widget.isComposerEnabled &&
                          widget.onOpenDevices != null)))
                gutter(
                  _EngineUnreachableNotice(
                    message: widget.errorMessage == null
                        ? 'No engine is reachable'
                        : describeChatError(widget.errorMessage!),
                    onOpenDevices: widget.isComposerEnabled
                        ? null
                        : widget.onOpenDevices,
                  ),
                ),
              if (!overlay && widget.executors != null)
                gutter(TaskStatusBar(provider: widget.provider)),
              if (!overlay && _voice.realtime != RealtimeState.off)
                gutter(_VoiceBanner(voice: _voice, onEnd: _toggleRealtime)),
              if (!overlay)
                gutter(
                  _Composer(
                    borderless: widget.borderlessComposer,
                    minTouchTarget: widget.minTouchTarget,
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
                            minTouchTarget: widget.minTouchTarget,
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

final class _EngineUnreachableNotice extends StatelessWidget {
  const _EngineUnreachableNotice({required this.message, this.onOpenDevices});

  final String message;
  final VoidCallback? onOpenDevices;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey<String>('engine-unreachable-notice'),
    padding: const EdgeInsets.only(bottom: 8),
    child: AppBanner(
      tone: AppBannerTone.warning,
      message: message,
      actions: <Widget>[
        if (onOpenDevices != null)
          TextButton(onPressed: onOpenDevices, child: const Text('Devices')),
      ],
    ),
  );
}

final class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.title,
    required this.canCreateThread,
    required this.canEditThread,
    required this.settingsVisible,
    required this.onCreateThread,
    required this.onEditThread,
    this.threadsVisible = false,
    this.onToggleThreads,
    this.minTouchTarget,
  });

  final String title;
  final bool canCreateThread;
  final bool canEditThread;
  final bool settingsVisible;
  final VoidCallback onCreateThread;
  final VoidCallback onEditThread;

  /// Whether the thread list is open, and the button that opens it (null hides
  /// the button).
  final bool threadsVisible;
  final VoidCallback? onToggleThreads;
  final double? minTouchTarget;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Row(
        children: <Widget>[
          // The thread's name is a long button that opens its settings.
          Expanded(
            child: Tooltip(
              message: settingsVisible
                  ? 'Close thread settings'
                  : 'Thread settings',
              child: AppListRow(
                title: title,
                titleBold: true,
                dense: true,
                minHeight: minTouchTarget,
                selected: settingsVisible,
                semanticLabel: 'Thread settings: $title',
                trailing: const Icon(FluentIcons.settings_16_regular, size: 16),
                onTap: canEditThread ? onEditThread : null,
              ),
            ),
          ),
          const SizedBox(width: 4),
          AppIconButton(
            tooltip: 'New thread',
            icon: FluentIcons.add_20_regular,
            minTouchTarget: minTouchTarget,
            onPressed: canCreateThread ? onCreateThread : null,
          ),
          if (onToggleThreads != null) ...<Widget>[
            const SizedBox(width: 4),
            AppIconButton(
              tooltip: threadsVisible ? 'Close threads' : 'Threads',
              icon: FluentIcons.chat_multiple_20_regular,
              selected: threadsVisible,
              minTouchTarget: minTouchTarget,
              onPressed: onToggleThreads,
            ),
          ],
        ],
      ),
    ),
  );
}

final class _EmptyChat extends StatelessWidget {
  const _EmptyChat({this.name});

  /// The user's first name, when known.
  final String? name;

  /// A greeting for the time of day.
  static String greeting(DateTime now, String? name) {
    final String period = now.hour < 5
        ? 'Hello'
        : now.hour < 12
        ? 'Good morning'
        : now.hour < 18
        ? 'Good afternoon'
        : 'Good evening';
    final String who = name?.trim() ?? '';
    return who.isEmpty ? period : '$period, $who';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              greeting(DateTime.now(), name),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'What would you like to work on?',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.timestamp,
    this.onSpeak,
    this.isSpeaking = false,
    this.streaming = false,
    this.minTouchTarget,
  });

  /// True while the reply is still arriving; its open markdown is closed for
  /// display so it is formatted as it streams.
  final bool streaming;

  /// Reads the message aloud; null when no text-to-speech model is set up.
  final VoidCallback? onSpeak;
  final bool isSpeaking;
  final EngineChatMessage message;
  final DateTime? timestamp;
  final double? minTouchTarget;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool isUser = message.origin == EngineChatMessageOrigin.user;
    final bool isSystem = message.origin == EngineChatMessageOrigin.system;
    final bool isAssistant =
        message.origin == EngineChatMessageOrigin.assistant;
    final Color metadataForeground = isUser
        ? colors.onSecondaryContainer.withValues(alpha: 0.7)
        : colors.onSurfaceVariant;
    final String text = message.text;
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (isAssistant)
          MarkdownPreview(
            text: streaming ? completeStreamingMarkdown(text) : text,
            embedded: true,
            debounce: Duration.zero,
          )
        else
          Text.rich(
            _withReferencePills(
              context,
              text,
              textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
          ),
        Row(
          children: <Widget>[
            if (timestamp != null)
              Text(
                _formatTimestamp(timestamp!),
                style: textTheme.labelSmall?.copyWith(
                  color: metadataForeground,
                ),
              ),
            if (isAssistant && message.ranOn != null)
              NodeBadge(name: message.ranOn!),
            if (isAssistant && message.elapsed != null)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(
                  _formatElapsed(message.elapsed!),
                  style: textTheme.labelSmall?.copyWith(
                    color: metadataForeground,
                  ),
                ),
              ),
            if (isAssistant && (message.tokens ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(
                  '${message.tokensEstimated ? '~' : ''}${message.tokens} tokens',
                  style: textTheme.labelSmall?.copyWith(
                    color: metadataForeground,
                  ),
                ),
              ),
            const Spacer(),
            if (onSpeak != null)
              AppIconButton(
                tooltip: isSpeaking ? 'Stop reading' : 'Read aloud',
                icon: isSpeaking
                    ? FluentIcons.stop_16_regular
                    : FluentIcons.speaker_2_16_regular,
                iconSize: 16,
                minTouchTarget: minTouchTarget,
                onPressed: onSpeak,
              ),
            AppIconButton(
              tooltip: 'Copy message',
              icon: FluentIcons.copy_16_regular,
              iconSize: 16,
              minTouchTarget: minTouchTarget,
              onPressed: text.isEmpty
                  ? null
                  : () => Clipboard.setData(ClipboardData(text: text)),
            ),
          ],
        ),
      ],
    );
    final AppMessageRole role = isSystem
        ? AppMessageRole.system
        : isUser
        ? AppMessageRole.user
        : AppMessageRole.assistant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppMessageBubble(
        role: role,
        boxed: !isAssistant,
        maxWidthFraction: isUser ? 0.82 : 1,
        child: isSystem
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Notification',
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  content,
                ],
              )
            : content,
      ),
    );
  }
}

final class _ToolApprovalCard extends StatefulWidget {
  const _ToolApprovalCard({required this.request, required this.onDecision});

  final ToolApprovalRequest request;
  final ValueChanged<bool>? onDecision;

  @override
  State<_ToolApprovalCard> createState() => _ToolApprovalCardState();
}

final class _ToolApprovalCardState extends State<_ToolApprovalCard> {
  /// Longest value shown on one row before it is cut with an ellipsis.
  static const int _valueLimit = 160;

  bool _showAll = false;

  /// The operation as shown to the user ('execute' reads as "Run").
  static String _operationLabel(String operation) => switch (operation) {
    'execute' => 'Run',
    'read' => 'Read',
    'update' => 'Update',
    'delete' => 'Delete',
    _ => operation,
  };

  static String _describe(Object? value) {
    final String text = value is String ? value : jsonEncode(value);
    return text.length <= _valueLimit
        ? text
        : '${text.substring(0, _valueLimit)}…';
  }

  @override
  void didUpdateWidget(_ToolApprovalCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different request starts collapsed again.
    if (oldWidget.request.approvalId != widget.request.approvalId) {
      _showAll = false;
    }
  }

  /// One line that says what is being asked, shown while collapsed.
  static String _summary(Map<String, dynamic> arguments) {
    if (arguments.isEmpty) return 'no arguments';
    return arguments.entries
        .map(
          (MapEntry<String, dynamic> entry) =>
              '${entry.key}: ${_describe(entry.value)}',
        )
        .join(', ');
  }

  /// Every argument on its own line, plus what approving covers.
  Widget _details(BuildContext context, ColorScheme colors) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final List<MapEntry<String, dynamic>> entries = widget
        .request
        .arguments
        .entries
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (entries.isEmpty)
          Text(
            'No arguments.',
            style: textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.55),
                borderRadius: AppRadii.standard,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final MapEntry<String, dynamic> entry in entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text.rich(
                            TextSpan(
                              children: <InlineSpan>[
                                TextSpan(
                                  text: '${entry.key}: ',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                TextSpan(
                                  text: entry.value is String
                                      ? entry.value as String
                                      : jsonEncode(entry.value),
                                ),
                              ],
                            ),
                            style: textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 6),
        Text(
          'Approve once runs this call only; you are asked again next time. '
          'Deny stops it and tells the assistant it was refused.',
          style: textTheme.labelSmall,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ToolApprovalRequest request = widget.request;
    final ValueChanged<bool>? onDecision = widget.onDecision;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: AppBanner(
        tone: AppBannerTone.warning,
        preface: request.remote
            ? Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${request.peerName ?? 'Another device'} wants to use a tool '
                  'on this device',
                  key: const ValueKey<String>('remote-approval-peer'),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              )
            : null,
        title: 'Approval required: ${request.toolName}',
        message:
            '${_operationLabel(request.operation)}: '
            '${_summary(request.arguments)}',
        messageMaxLines: _showAll ? 1 : 2,
        content: _showAll ? _details(context, colors) : null,
        actions: <Widget>[
          TextButton(
            onPressed: () => setState(() => _showAll = !_showAll),
            child: Text(_showAll ? 'Hide details' : 'Details'),
          ),
          TextButton(
            onPressed: onDecision == null ? null : () => onDecision(false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: onDecision == null ? null : () => onDecision(true),
            child: const Text('Approve once'),
          ),
        ],
      ),
    );
  }
}

/// A tool needs the user to sign in. The browser step may land on a page this
/// device cannot reach (the engine redirects to its own loopback address), so
/// pasting the address the browser ended on is a first-class path.
final class _OAuthSignInCard extends StatefulWidget {
  const _OAuthSignInCard({
    required this.authorization,
    required this.onOpen,
    required this.onPaste,
    required this.onCancel,
    this.error,
  }) : super(key: const ValueKey<String>('oauth-signin-card'));

  final OAuthAuthorization authorization;
  final VoidCallback? onOpen;
  final ValueChanged<String>? onPaste;
  final VoidCallback? onCancel;
  final String? error;

  @override
  State<_OAuthSignInCard> createState() => _OAuthSignInCardState();
}

final class _OAuthSignInCardState extends State<_OAuthSignInCard> {
  final TextEditingController _pasted = TextEditingController();

  @override
  void initState() {
    super.initState();
    _pasted.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(_OAuthSignInCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different sign-in must not inherit text pasted for the previous one.
    if (oldWidget.authorization.authId != widget.authorization.authId) {
      _pasted.clear();
    }
  }

  @override
  void dispose() {
    _pasted.removeListener(_onTextChanged);
    _pasted.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  bool get _canSubmit =>
      widget.onPaste != null && _pasted.text.trim().isNotEmpty;

  void _submit() {
    if (_canSubmit) widget.onPaste!(_pasted.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String toolName = widget.authorization.toolName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: AppBanner(
        tone: AppBannerTone.warning,
        title: toolName.isEmpty ? 'Sign in' : 'Sign in to $toolName',
        message:
            'Continue in your browser. If this device is not the one running '
            'the engine, copy the address you end up on and paste it below.',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: widget.onOpen,
                child: const Text('Open sign-in page'),
              ),
            ),
            const SizedBox(height: 8),
            AppFormTheme(
              child: AppTextField(
                controller: _pasted,
                onSubmitted: (_) => _submit(),
                hintText: 'Paste the address or code',
              ),
            ),
            if (widget.error case final String message)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  message,
                  key: const ValueKey<String>('oauth-signin-error'),
                  style: text.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
          FilledButton(
            onPressed: _canSubmit ? _submit : null,
            child: const Text('Submit'),
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
    this.borderless = false,
    this.minTouchTarget,
  });

  /// Drops the outline around the composer (mobile layout).
  final bool borderless;
  final double? minTouchTarget;

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
        border: borderless ? null : Border.all(color: colors.outlineVariant),
        borderRadius: AppRadii.standard,
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
                  top: Radius.circular(AppRadii.value),
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
                      child: AppBadge(
                        'Active: ${file.label}',
                        icon: FluentIcons.edit_20_regular,
                        maxWidth: 180,
                      ),
                    ),
                  for (final ChatAttachment attachment in attachments)
                    Tooltip(
                      message: attachment.name,
                      child: AppBadge(
                        attachment.name,
                        icon: FluentIcons.attach_20_regular,
                        maxWidth: 180,
                        deleteTooltip: 'Remove ${attachment.name}',
                        onDeleted: interactive
                            ? () => onRemoveAttachment(attachment.id)
                            : null,
                      ),
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
                AppIconButton(
                  tooltip: 'Attach files',
                  icon: FluentIcons.attach_20_regular,
                  iconSize: 19,
                  minTouchTarget: minTouchTarget,
                  onPressed: interactive && attachments.length < 5
                      ? onAddAttachment
                      : null,
                ),
                if (voice.canDictate) ...<Widget>[
                  AppSpacing.controlGap,
                  _DictationButton(
                    state: voice.dictation,
                    enabled: enabled && voice.realtime == RealtimeState.off,
                    onPressed: onToggleDictation,
                    minTouchTarget: minTouchTarget,
                  ),
                ],
                if (voice.canRealtime) ...<Widget>[
                  AppSpacing.controlGap,
                  AppIconButton(
                    tooltip: voice.realtime == RealtimeState.off
                        ? 'Talk (realtime voice)'
                        : 'End voice conversation',
                    icon: FluentIcons.headphones_sound_wave_20_regular,
                    iconSize: 19,
                    selected: voice.realtime != RealtimeState.off,
                    minTouchTarget: minTouchTarget,
                    onPressed: enabled ? onToggleRealtime : null,
                  ),
                ],
                AppSpacing.controlGap,
                Expanded(
                  child: AppCompactDropdown<String>(
                    height: minTouchTarget == null || minTouchTarget! < 32
                        ? 32
                        : minTouchTarget!,
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
                AppSpacing.controlGap,
                if (executorPicker case final Widget picker) ...<Widget>[
                  picker,
                  AppSpacing.controlGap,
                ],
                AppIconButton(
                  tooltip: !enabled
                      ? 'Engine unavailable'
                      : isSending
                      ? 'Send to the running agent'
                      : 'Send',
                  icon: FluentIcons.send_20_regular,
                  minTouchTarget: minTouchTarget,
                  onPressed: enabled ? onSend : null,
                ),
                if (isSending) ...<Widget>[
                  AppSpacing.controlGap,
                  AppIconButton(
                    tooltip: 'Stop',
                    icon: FluentIcons.stop_20_regular,
                    minTouchTarget: minTouchTarget,
                    onPressed: onStop,
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
    this.minTouchTarget,
  });

  final DictationState state;
  final bool enabled;
  final VoidCallback onPressed;
  final double? minTouchTarget;

  @override
  Widget build(BuildContext context) {
    final double dimension = minTouchTarget == null || minTouchTarget! < 32
        ? 32
        : minTouchTarget!;
    return switch (state) {
      DictationState.transcribing => SizedBox.square(
        dimension: dimension,
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      DictationState.recording => AppIconButton(
        tooltip: 'Stop recording',
        icon: FluentIcons.stop_20_filled,
        iconSize: 18,
        selected: true,
        destructive: true,
        minTouchTarget: minTouchTarget,
        onPressed: onPressed,
      ),
      DictationState.idle => AppIconButton(
        tooltip: 'Dictate a message',
        icon: FluentIcons.mic_20_regular,
        iconSize: 19,
        minTouchTarget: minTouchTarget,
        onPressed: enabled ? onPressed : null,
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
    final VoiceLine? last = voice.lines.isEmpty ? null : voice.lines.last;
    final String status = voice.realtime == RealtimeState.connecting
        ? 'Connecting…'
        : voice.toolActivity != null
        ? 'Working on it…'
        : 'Listening';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: AppBanner(
        title: status,
        message: last == null
            ? ''
            : '${last.role == 'user' ? 'You' : 'Assistant'}: ${last.text}',
        messageMaxLines: 2,
        actions: <Widget>[
          TextButton(onPressed: onEnd, child: const Text('End')),
        ],
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
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: AppBadge(label, icon: FluentIcons.document_20_regular),
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

void _showErrorToast(BuildContext context, String message) => showAppSnack(
  context,
  message,
  isError: true,
  duration: const Duration(seconds: 5),
  margin: _panelToastMargin(context),
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
            final Widget actions = AppButtonRow(
              children: <Widget>[
                AppIconButton(
                  tooltip: 'Cancel thread settings',
                  icon: FluentIcons.dismiss_20_regular,
                  onPressed: _saving ? null : widget.onCancel,
                ),
                AppIconButton(
                  tooltip: 'Save thread settings',
                  icon: FluentIcons.save_20_regular,
                  busy: _saving,
                  onPressed: _loading || _saving ? null : _submit,
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
        AppFormTheme(
          child: AppTextField(
            label: 'Thread name',
            controller: _titleController,
            autofocus: widget.isDraft,
            enabled: !_saving,
            hintText: 'New thread',
          ),
        ),
        if (widget.threadUuid case final String threadUuid) ...<Widget>[
          const AppFieldLabel('Thread UUID'),
          AppFieldRow(
            field: AppFormTheme(
              child: AppTextField(
                key: ValueKey<String>(threadUuid),
                initialValue: threadUuid,
                readOnly: true,
                height: 32,
              ),
            ),
            actions: <Widget>[
              AppIconButton(
                outlined: true,
                tooltip: 'Copy thread UUID',
                icon: FluentIcons.copy_20_regular,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: threadUuid));
                  if (context.mounted) {
                    showAppSnack(context, 'Thread UUID copied');
                  }
                },
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
        ToolPolicyList(
          catalog: _catalog,
          editable: _toolsEditable,
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
        AppSwitch(value: value, onChanged: onChanged, semanticLabel: title),
      ],
    ),
  );

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
}
