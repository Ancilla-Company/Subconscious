import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart' as core;
import 'package:flutter/foundation.dart';

/// What a timeline entry is. [tool] entries are not model replies: they record
/// a tool call (with its approval and any sub-agent steps) and are shown as
/// collapsed activity cards.
enum EngineChatMessageOrigin { user, assistant, system, tool }

final class EngineChatMessage {
  EngineChatMessage.user(String text)
    : origin = EngineChatMessageOrigin.user,
      _text = text;

  EngineChatMessage.assistant([String text = ''])
    : origin = EngineChatMessageOrigin.assistant,
      _text = text;

  EngineChatMessage.system(String text)
    : origin = EngineChatMessageOrigin.system,
      _text = text;

  EngineChatMessage.tool(core.ToolCallInfo call)
    : origin = EngineChatMessageOrigin.tool,
      toolCall = call,
      _text = '';

  final EngineChatMessageOrigin origin;
  String _text;

  /// The tool call of a [EngineChatMessageOrigin.tool] entry.
  core.ToolCallInfo? toolCall;

  /// Uuid of the stored message this entry shows; null while it only exists
  /// on this device (a reply still streaming, or one not yet reloaded).
  String? serverId;

  /// Name of the hive node that produced this message, when known (shown as
  /// a badge on assistant messages).
  String? ranOn;

  /// Time the response took and tokens used (estimated when the engine does
  /// not report usage).
  Duration? elapsed;
  int? tokens;
  bool tokensEstimated = false;

  String get text => _text;

  void append(String value) => _text += value;
}

final class EngineLlmProvider extends ChangeNotifier {
  EngineLlmProvider({
    this.repository,
    this.threadUuid,
    this.workspaceUuid,
    this.modelId,
  });

  /// Null while no engine is connected: the thread is shown from what was
  /// loaded earlier and the composer is disabled.
  core.EngineRepository? repository;

  /// The connected repository; throws [StateError] while disconnected.
  core.EngineRepository get engine => _engine;

  core.EngineRepository get _engine =>
      repository ??
      (throw StateError('The Subconscious engine is not connected.'));
  String? threadUuid;
  String? workspaceUuid;
  String? modelId;

  /// Node that should run the next message; null runs it on the connected
  /// engine through the unchanged chat path.
  String? executorNodeId;

  /// Resolves a node id to a display name (set by the app from the hive
  /// directory).
  String? Function(String nodeId)? nodeNameOf;

  /// State of the task started by the latest remote-executor message.
  core.TaskStatus? taskStatus;
  String? activeTaskId;
  String? taskExecutorNodeId;
  String? taskError;

  /// Latest task row of the thread from `GET /api/v1/hive/tasks`, if read.
  core.TaskRecord? lastTask;

  String? get executorLabel {
    final String? id = executorNodeId;
    return id == null ? null : (nodeNameOf?.call(id) ?? id);
  }

  /// Executor name for the thread badge: the running task, else the last one.
  String? get ranOnLabel {
    final String? id = taskExecutorNodeId ?? lastTask?.executorNodeId;
    return id == null ? null : (nodeNameOf?.call(id) ?? id);
  }

  bool get hasActiveTask {
    final core.TaskStatus? status = taskStatus;
    return status != null && !status.isTerminal;
  }

  void selectExecutor(String? nodeId) {
    if (executorNodeId == nodeId) return;
    executorNodeId = nodeId;
    notifyListeners();
  }

  /// Asks the executor to stop the active task (`task.cancel`).
  void cancelActiveTask() {
    final String? id = activeTaskId;
    if (id == null || !hasActiveTask) return;
    try {
      repository?.socket.cancelTask(id);
    } on Object {
      // The connection may be gone; the status stays until the next frame.
    }
  }

  /// Best-effort read of the thread's latest task (works for thin clients
  /// through the REST tunnel; failures are ignored).
  Future<void> refreshTaskInfo() async {
    final String? thread = threadUuid;
    if (thread == null) return;
    try {
      final core.EngineRepository? engine = repository;
      if (engine == null) return;
      final List<core.TaskRecord> tasks = await engine.listTasks(
        threadUuid: thread,
      );
      if (tasks.isEmpty) return;
      lastTask = tasks.reduce(
        (core.TaskRecord a, core.TaskRecord b) =>
            (a.createdAt ?? '').compareTo(b.createdAt ?? '') >= 0 ? a : b,
      );
      notifyListeners();
    } on Object {
      // Older engines or restricted routes: the badge relies on task.status.
    }
  }

  final List<EngineChatMessage> _history = <EngineChatMessage>[];
  final Map<EngineChatMessage, DateTime?> _timestamps =
      <EngineChatMessage, DateTime?>{};

  void replaceRepository(core.EngineRepository repository) {
    if (identical(this.repository, repository)) return;
    this.repository = repository;
    notifyListeners();
  }

  void bindThread(String uuid) {
    threadUuid = uuid;
    workspaceUuid = null;
    notifyListeners();
  }

  DateTime? timestampFor(EngineChatMessage message) => _timestamps[message];

  void selectModel(String? value) {
    modelId = value;
    notifyListeners();
  }

  /// Replaces the timeline with the stored thread.
  ///
  /// While a turn runs here, the engine is already storing its text and tool
  /// calls piece by piece, and the same pieces are on screen as live entries.
  /// Stored messages this timeline has not shown before therefore belong to
  /// that turn and are skipped; the live entries stay, so nothing is shown
  /// twice and nothing disappears mid-turn. Once the turn ends, the next
  /// refresh swaps everything for the stored copy.
  void replaceEngineHistory(Iterable<core.ChatMessage> messages) {
    final bool running = _activeTurns > 0;
    final Set<String> known = <String>{
      for (final EngineChatMessage message in _history)
        if (message.serverId != null) message.serverId!,
    };
    final Map<EngineChatMessage, DateTime?> local =
        <EngineChatMessage, DateTime?>{
          if (running)
            for (final EngineChatMessage message in _history)
              if (message.serverId == null) message: _timestamps[message],
        };
    _history.clear();
    _timestamps.clear();
    for (final core.ChatMessage message in messages) {
      if (running && !known.contains(message.uuid)) continue;
      final EngineChatMessage? converted = switch (message.role.toLowerCase()) {
        'user' => EngineChatMessage.user(message.content),
        'assistant' => EngineChatMessage.assistant(message.content),
        'system' => EngineChatMessage.system(message.content),
        'tool' => switch (core.ToolCallInfo.tryParseRecord(
          message.content,
          id: message.uuid,
        )) {
          final core.ToolCallInfo call => EngineChatMessage.tool(call),
          null => null,
        },
        _ => null,
      };
      if (converted != null) {
        converted.serverId = message.uuid;
        _history.add(converted);
        _timestamps[converted] = message.createdAt;
      }
    }
    for (final MapEntry<EngineChatMessage, DateTime?> entry in local.entries) {
      _history.add(entry.key);
      _timestamps[entry.key] = entry.value;
    }
    notifyListeners();
  }

  /// True while [message] is still being written by a running turn.
  bool isStreaming(EngineChatMessage message) => _live.contains(message);

  // --- the turn being shown live -------------------------------------------

  /// Turns currently streaming into this timeline.
  int _activeTurns = 0;

  /// The reply bubble text is being appended to; null between bubbles (after
  /// a tool call, until the model says something new).
  EngineChatMessage? _openBubble;

  /// The last reply bubble of the turn; it gets the timing and token counts.
  EngineChatMessage? _lastBubble;
  final Map<String, EngineChatMessage> _toolCards = <String, EngineChatMessage>{};

  EngineChatMessage _startBubble() {
    final EngineChatMessage bubble = EngineChatMessage.assistant()
      ..ranOn = executorLabel;
    _history.add(bubble);
    _timestamps[bubble] = DateTime.now();
    _live.add(bubble);
    _openBubble = bubble;
    return bubble;
  }

  /// Ends the current reply bubble. One that never got any text is dropped.
  void _closeBubble() {
    final EngineChatMessage? bubble = _openBubble;
    if (bubble == null) return;
    _openBubble = null;
    _live.remove(bubble);
    if (bubble.text.isEmpty) {
      _history.remove(bubble);
      _timestamps.remove(bubble);
    } else {
      _lastBubble = bubble;
    }
  }

  /// Shows a tool event in order: text said so far stays in its bubble, the
  /// call gets its own card, and later text starts a new bubble below it.
  void _applyActivity(core.ChatActivity activity) {
    switch (activity) {
      case core.ChatToolCall(:final call):
        final EngineChatMessage? card = _toolCards[call.toolCallId];
        if (card == null) {
          _closeBubble();
          final EngineChatMessage created = EngineChatMessage.tool(call);
          _toolCards[call.toolCallId] = created;
          _history.add(created);
          _timestamps[created] = DateTime.now();
        } else {
          card.toolCall = card.toolCall!.copyWith(
            title: call.title,
            kind: call.kind,
            status: call.status,
            arguments: call.arguments,
            output: call.output,
            error: call.error,
          );
        }
      case core.ChatToolProgress(:final toolCallId, :final step):
        final EngineChatMessage? card = _toolCards[toolCallId];
        if (card == null) return;
        card.toolCall = card.toolCall!.withStep(step);
    }
    notifyListeners();
  }

  Iterable<EngineChatMessage> get history =>
      List<EngineChatMessage>.unmodifiable(_history);

  set history(Iterable<EngineChatMessage> value) {
    _history
      ..clear()
      ..addAll(value);
    _timestamps.clear();
    notifyListeners();
  }

  Stream<String> generateStream(String prompt) async* {
    yield* _stream(prompt);
  }

  Stream<String> sendMessageStream(
    String prompt, {
    core.ChatFileContext? fileContext,
  }) async* {
    final EngineChatMessage user = EngineChatMessage.user(prompt);
    _history.add(user);
    _timestamps[user] = DateTime.now();
    _activeTurns++;
    _lastBubble = null;
    _toolCards.clear();
    _startBubble(); // shows the "typing" state until the first text or tool call
    notifyListeners();
    try {
      final Stopwatch watch = Stopwatch()..start();
      Map<String, dynamic>? doneData;
      await for (final String delta in _stream(
        prompt,
        fileContext: fileContext,
        onDone: (Map<String, dynamic> data) => doneData = data,
        onActivity: _applyActivity,
      )) {
        (_openBubble ?? _startBubble()).append(delta);
        notifyListeners();
        yield delta;
      }
      watch.stop();
      _closeBubble();
      final EngineChatMessage? response = _lastBubble;
      if (response != null) {
        final Object? elapsedMs = doneData?['elapsed_ms'];
        response.elapsed = elapsedMs is num
            ? Duration(milliseconds: elapsedMs.toInt())
            : watch.elapsed;
        final int? total = _totalTokens(doneData);
        final bool reported = total != null && total > 0;
        response.tokens = reported ? total : (response.text.length / 4).ceil();
        response.tokensEstimated = !reported;
      }
      notifyListeners();
    } on Object {
      // What was said and done before the failure stays on screen (the engine
      // stores it too); only a bubble that never got any text is dropped.
      _closeBubble();
      notifyListeners();
      rethrow;
    } finally {
      _closeBubble();
      _activeTurns--;
      _toolCards.clear();
    }
  }

  final List<EngineChatMessage> _live = <EngineChatMessage>[];
  StreamSubscription<String>? _turnSubscription;
  Completer<void>? _turnCompletion;

  /// Last failure of a turn that ran without a panel attached to report it.
  Object? lastError;

  /// True while a turn is running. It keeps running when the user opens
  /// another thread; the panel reattaches to the same provider on return.
  bool get isBusy => _turnSubscription != null;

  /// Starts a turn that this provider owns, so it survives the panel going
  /// away. Completes when the turn ends and fails if the turn failed.
  Future<void> runTurn(String prompt, {core.ChatFileContext? fileContext}) {
    final Completer<void> completion = Completer<void>();
    lastError = null;
    late final StreamSubscription<String> subscription;
    subscription = sendMessageStream(prompt, fileContext: fileContext).listen(
      (_) {
        // Notifications from sendMessageStream redraw the streaming response.
      },
      onError: (Object error, StackTrace stackTrace) {
        lastError = error;
        if (!completion.isCompleted)
          completion.completeError(error, stackTrace);
      },
      onDone: () {
        if (!completion.isCompleted) completion.complete();
      },
      cancelOnError: true,
    );
    _turnSubscription = subscription;
    _turnCompletion = completion;
    unawaited(
      completion.future.then<void>((_) {}, onError: (_) {}).whenComplete(() {
        if (identical(_turnSubscription, subscription)) {
          _turnSubscription = null;
          _turnCompletion = null;
        }
        unawaited(subscription.cancel());
        notifyListeners();
      }),
    );
    notifyListeners();
    return completion.future;
  }

  /// Stops the running turn (the engine cancels it and keeps partial text).
  Future<void> cancelTurn() async {
    final StreamSubscription<String>? subscription = _turnSubscription;
    final Completer<void>? completion = _turnCompletion;
    if (subscription == null) return;
    await subscription.cancel();
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  @override
  void dispose() {
    unawaited(cancelTurn());
    super.dispose();
  }

  /// Sends a message while a turn is running. The engine injects it into the
  /// running agent; if it arrives too late the engine answers it as a
  /// follow-up turn on the same stream. Returns false when it cannot be sent.
  bool sendSteeringMessage(
    String prompt, {
    void Function(Object error)? onError,
  }) {
    final String? thread = threadUuid;
    if (thread == null || executorNodeId != null) return false;
    final EngineChatMessage user = EngineChatMessage.user(prompt);
    _history.add(user);
    _timestamps[user] = DateTime.now();
    notifyListeners();
    EngineChatMessage? response;
    _engine
        .streamChat(content: prompt, threadUuid: thread, modelId: modelId)
        .listen((String delta) {
          // Deltas only arrive when the message became a follow-up turn.
          if (response == null) {
            response = EngineChatMessage.assistant()..ranOn = executorLabel;
            _history.add(response!);
            _timestamps[response!] = DateTime.now();
          }
          response!.append(delta);
          notifyListeners();
        }, onError: (Object error) => onError?.call(error));
    return true;
  }

  Stream<String> _stream(
    String prompt, {
    core.ChatFileContext? fileContext,
    void Function(Map<String, dynamic>)? onDone,
    void Function(core.ChatActivity)? onActivity,
  }) {
    final String? executor = executorNodeId;
    if (executor == null) {
      return _engine.streamChat(
        content: prompt,
        threadUuid: threadUuid,
        workspaceUuid: workspaceUuid,
        modelId: modelId,
        fileContext: fileContext,
        onActivity: onActivity,
      );
    }
    return _runTask(prompt, executor, fileContext, onActivity);
  }

  Stream<String> _runTask(
    String prompt,
    String executor,
    core.ChatFileContext? fileContext,
    void Function(core.ChatActivity)? onActivity,
  ) async* {
    taskStatus = core.TaskStatus.queued;
    activeTaskId = null;
    taskExecutorNodeId = executor;
    taskError = null;
    notifyListeners();
    try {
      await for (final core.TaskEvent event in _engine.runTask(
        content: prompt,
        threadUuid: threadUuid,
        workspaceUuid: workspaceUuid,
        executor: executor,
        modelId: modelId,
        fileContext: fileContext,
      )) {
        switch (event) {
          case core.TaskAccepted():
            activeTaskId = event.task.taskId;
            taskStatus = event.task.status;
            taskExecutorNodeId = event.task.executorNodeId ?? executor;
            notifyListeners();
          case core.TaskStatusChanged():
            taskStatus = event.task.status;
            taskError = event.task.error ?? taskError;
            lastTask = event.task;
            notifyListeners();
          case core.TaskDelta():
            yield event.delta;
          case core.TaskActivity():
            onActivity?.call(event.activity);
          case core.TaskChatError():
            taskError = event.error;
            notifyListeners();
          default:
            break;
        }
      }
    } on Object catch (error) {
      final core.TaskStatus? status = taskStatus;
      if (status == null || !status.isTerminal) {
        taskStatus = core.TaskStatus.failed;
      }
      taskError ??= '$error';
      notifyListeners();
      rethrow;
    }
  }
}

int? _totalTokens(Map<String, dynamic>? data) {
  if (data == null) return null;
  final Object? usage = data['usage'] is Map ? data['usage'] : data;
  if (usage is! Map) return null;
  int? read(String key) {
    final Object? v = usage[key];
    return v is num ? v.toInt() : null;
  }

  final int? total = read('total_tokens') ?? read('totalTokens');
  if (total != null) return total;
  final int? input = read('input_tokens') ?? read('prompt_tokens');
  final int? output = read('output_tokens') ?? read('completion_tokens');
  return input == null && output == null ? null : (input ?? 0) + (output ?? 0);
}
