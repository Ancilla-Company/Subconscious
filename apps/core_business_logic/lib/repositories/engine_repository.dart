import 'dart:async';

import '../api/rest_engine_client.dart';
import '../api/engine_socket.dart';
import '../api/task_socket_mixin.dart';
import '../models/engine_models.dart';
import '../models/task_models.dart';

final class EngineRepository {
  const EngineRepository({required this.rest, required this.socket});
  final RestEngineClient rest;
  final EngineSocket socket;

  Future<void> connect() => socket.connect();
  Future<List<Workspace>> listWorkspaces() => rest.listWorkspaces();
  Future<List<ThreadInfo>> listThreads(String workspaceUuid) =>
      rest.listThreads(workspaceUuid);
  Future<List<ChatMessage>> listMessages(String threadUuid) =>
      rest.listMessages(threadUuid);
  Future<List<ModelInfo>> listModels() => rest.listModels();
  Future<List<TaskRecord>> listTasks({String? status, String? threadUuid}) =>
      rest.listTasks(status: status, threadUuid: threadUuid);

  /// Submits a task (`task.submit`) and streams its progress: [TaskAccepted],
  /// [TaskStatusChanged], [TaskDelta] and approval events for this task.
  ///
  /// [executor] is a hive node id; null runs on the connected engine. Completes
  /// when the task reaches a terminal status (a chat terminal frame without a
  /// status within [statusGrace] also ends it). Throws [StateError] when the
  /// submit is refused, the task fails or is interrupted. Abandoning the
  /// stream before the task ends sends `task.cancel`.
  Stream<TaskEvent> runTask({
    required String content,
    String? threadUuid,
    String? workspaceUuid,
    String? executor,
    String? modelId,
    ChatFileContext? fileContext,
    Duration statusGrace = const Duration(seconds: 3),
  }) async* {
    final String clientMsgUuid = newClientMessageId();
    final StreamController<TaskEvent> buffer = StreamController<TaskEvent>();
    final StreamSubscription<TaskEvent> subscription = socket.taskEvents.listen(
      buffer.add,
      onError: buffer.addError,
    );
    final StreamIterator<TaskEvent> iterator = StreamIterator<TaskEvent>(
      buffer.stream,
    );
    String? taskId;
    bool finished = false;
    bool chatEnded = false;
    try {
      final String submitId = socket.submitTask(
        content: content,
        threadUuid: threadUuid,
        workspaceUuid: workspaceUuid,
        clientMsgUuid: clientMsgUuid,
        executor: executor,
        modelId: modelId,
        fileContext: fileContext,
      );
      while (true) {
        final bool hasNext = chatEnded
            ? await iterator.moveNext().timeout(
                statusGrace,
                onTimeout: () => false,
              )
            : await iterator.moveNext();
        if (!hasNext) {
          finished = true;
          return;
        }
        final TaskEvent event = iterator.current;
        switch (event) {
          case TaskRejected():
            if (event.submitId == submitId ||
                event.clientMsgUuid == clientMsgUuid ||
                (taskId != null && event.taskId == taskId)) {
              finished = true;
              throw StateError(event.error);
            }
          case TaskAccepted():
            if (event.submitId == submitId) {
              taskId = event.task.taskId;
              yield event;
              if (event.task.status.isTerminal) {
                finished = true;
                return;
              }
            }
          case TaskStatusChanged():
            if (event.task.taskId != taskId) continue;
            yield event;
            if (event.task.status.isTerminal) {
              finished = true;
              final TaskRecord task = event.task;
              if (task.status == TaskStatus.failed ||
                  task.status == TaskStatus.interrupted) {
                throw StateError(task.error ?? 'The task ${task.status.name}.');
              }
              return;
            }
          case TaskDelta():
            if (event.taskId == taskId) yield event;
          case TaskChatDone():
            if (event.taskId == taskId) {
              chatEnded = true;
              yield event;
            }
          case TaskChatCancelled():
            if (event.taskId == taskId) {
              chatEnded = true;
              yield event;
            }
          case TaskChatError():
            if (event.taskId == taskId) {
              chatEnded = true;
              yield event;
            }
          case ToolApprovalRequested():
            if (taskId != null && event.taskId == taskId) yield event;
          case ToolApprovalResolved():
            if (taskId != null && event.taskId == taskId) yield event;
          case OAuthRequested():
            if (taskId != null && event.taskId == taskId) yield event;
          case OAuthResolved():
            if (taskId != null && event.taskId == taskId) yield event;
          case ThreadSubscribed():
            break;
        }
      }
    } finally {
      if (!finished && taskId != null && socket.isConnected) {
        try {
          socket.cancelTask(taskId);
        } on Object {
          // The transport may close while a stream cancellation propagates.
        }
      }
      await subscription.cancel();
      await iterator.cancel();
      await buffer.close();
    }
  }

  Stream<String> streamChat({
    required String content,
    String? threadUuid,
    String? workspaceUuid,
    String? modelId,
    ChatFileContext? fileContext,
  }) async* {
    final String turnId = socket.sendChat(
      content: content,
      threadUuid: threadUuid,
      workspaceUuid: workspaceUuid,
      modelId: modelId,
      fileContext: fileContext,
    );
    const Set<String> turnFrameTypes = <String>{
      'chat.delta',
      'chat.done',
      'chat.error',
      'chat.cancelled',
    };
    bool receivedTerminalFrame = false;
    try {
      await for (final WireFrame frame in socket.frames) {
        if (frame.type == 'error' && frame.id == null) {
          throw StateError(
            frame.data?['error'] as String? ??
                'Engine WebSocket request failed.',
          );
        }
        if (frame.id != turnId || !turnFrameTypes.contains(frame.type)) {
          continue;
        }
        final Map<String, dynamic> data = frame.data ?? <String, dynamic>{};
        switch (frame.type) {
          case 'chat.delta':
            final String delta = data['delta'] as String? ?? '';
            if (delta.isNotEmpty) yield delta;
          case 'chat.done':
            receivedTerminalFrame = true;
            return;
          case 'chat.cancelled':
            receivedTerminalFrame = true;
            throw StateError('Chat turn was cancelled.');
          case 'chat.error':
            receivedTerminalFrame = true;
            throw StateError(data['error'] as String? ?? 'Chat turn failed.');
        }
      }
    } finally {
      if (!receivedTerminalFrame && socket.isConnected) {
        try {
          socket.cancelChat(turnId);
        } on Object {
          // The transport may close while a stream cancellation is propagating.
        }
      }
    }
  }
}
