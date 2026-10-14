import 'package:core_business_logic/core_business_logic.dart' as core;
import 'package:flutter/foundation.dart';

enum EngineChatMessageOrigin { user, assistant, system }

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

  final EngineChatMessageOrigin origin;
  String _text;

  /// Name of the hive node that produced this message, when known (shown as
  /// a badge on assistant messages).
  String? ranOn;

  String get text => _text;

  void append(String value) => _text += value;
}

final class EngineLlmProvider extends ChangeNotifier {
  EngineLlmProvider({
    required this.repository,
    this.threadUuid,
    this.workspaceUuid,
    this.modelId,
  });

  core.EngineRepository repository;
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
      repository.socket.cancelTask(id);
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
      final List<core.TaskRecord> tasks = await repository.listTasks(
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

  void replaceEngineHistory(Iterable<core.ChatMessage> messages) {
    _history.clear();
    _timestamps.clear();
    for (final core.ChatMessage message in messages) {
      final EngineChatMessage? converted = switch (message.role.toLowerCase()) {
        'user' => EngineChatMessage.user(message.content),
        'assistant' => EngineChatMessage.assistant(message.content),
        'system' => EngineChatMessage.system(message.content),
        _ => null,
      };
      if (converted != null) {
        _history.add(converted);
        _timestamps[converted] = message.createdAt;
      }
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
    final EngineChatMessage response = EngineChatMessage.assistant();
    response.ranOn = executorLabel;
    _history.add(response);
    _timestamps[response] = DateTime.now();
    notifyListeners();
    try {
      await for (final String delta in _stream(
        prompt,
        fileContext: fileContext,
      )) {
        response.append(delta);
        notifyListeners();
        yield delta;
      }
    } on Object {
      _history.remove(response);
      _timestamps.remove(response);
      notifyListeners();
      rethrow;
    }
  }

  Stream<String> _stream(String prompt, {core.ChatFileContext? fileContext}) {
    final String? executor = executorNodeId;
    if (executor == null) {
      return repository.streamChat(
        content: prompt,
        threadUuid: threadUuid,
        workspaceUuid: workspaceUuid,
        modelId: modelId,
        fileContext: fileContext,
      );
    }
    return _runTask(prompt, executor, fileContext);
  }

  Stream<String> _runTask(
    String prompt,
    String executor,
    core.ChatFileContext? fileContext,
  ) async* {
    taskStatus = core.TaskStatus.queued;
    activeTaskId = null;
    taskExecutorNodeId = executor;
    taskError = null;
    notifyListeners();
    try {
      await for (final core.TaskEvent event in repository.runTask(
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
