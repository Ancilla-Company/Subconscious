import 'engine_models.dart';

/// Task lifecycle (webrtc.md 7.4): monotonic, written only by the executor.
enum TaskStatus {
  queued,
  running,
  waitingApproval,
  done,
  failed,
  cancelled,
  interrupted,
  unknown;

  bool get isTerminal => switch (this) {
    TaskStatus.done ||
    TaskStatus.failed ||
    TaskStatus.cancelled ||
    TaskStatus.interrupted => true,
    _ => false,
  };

  /// Wire name as used by the engine (`waiting_approval`).
  String get wireName =>
      this == TaskStatus.waitingApproval ? 'waiting_approval' : name;

  static TaskStatus parse(Object? value) => switch (value) {
    'queued' => TaskStatus.queued,
    'running' => TaskStatus.running,
    'waiting_approval' => TaskStatus.waitingApproval,
    'done' => TaskStatus.done,
    'failed' => TaskStatus.failed,
    'cancelled' => TaskStatus.cancelled,
    'interrupted' => TaskStatus.interrupted,
    _ => TaskStatus.unknown,
  };
}

/// Task row as sent in `task.accepted` / `task.status` and by
/// `GET /api/v1/hive/tasks`.
final class TaskRecord {
  const TaskRecord({
    required this.taskId,
    required this.status,
    this.threadUuid,
    this.workspaceUuid,
    this.executorNodeId,
    this.requesterNodeId,
    this.rev = 0,
    this.turnId,
    this.modelId,
    this.clientMsgUuid,
    this.error,
    this.createdAt,
    this.startedAt,
    this.finishedAt,
  });

  final String taskId;
  final TaskStatus status;
  final String? threadUuid;
  final String? workspaceUuid;
  final String? executorNodeId;
  final String? requesterNodeId;
  final int rev;
  final String? turnId;
  final String? modelId;
  final String? clientMsgUuid;
  final String? error;
  final String? createdAt;
  final String? startedAt;
  final String? finishedAt;

  static TaskRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['task_id'];
    if (id is! String || id.isEmpty) return null;
    String? text(String key) => raw[key] is String ? raw[key] as String : null;
    final Object? rev = raw['rev'];
    return TaskRecord(
      taskId: id,
      status: TaskStatus.parse(raw['status']),
      threadUuid: text('thread_uuid'),
      workspaceUuid: text('workspace_uuid'),
      executorNodeId: text('executor_node_id'),
      requesterNodeId: text('requester_node_id'),
      rev: rev is int ? rev : 0,
      turnId: text('turn_id'),
      modelId: text('model_id'),
      clientMsgUuid: text('client_msg_uuid'),
      error: text('error'),
      createdAt: text('created_at'),
      startedAt: text('started_at'),
      finishedAt: text('finished_at'),
    );
  }
}

/// Typed view of the task related wire frames. [taskId] is the engine task id
/// (the frame id of `task.status` and the per task `chat.*` frames).
sealed class TaskEvent {
  const TaskEvent();
}

/// `task.accepted`. [submitId] is the id of the `task.submit` frame.
final class TaskAccepted extends TaskEvent {
  const TaskAccepted(this.task, {this.submitId});
  final TaskRecord task;
  final String? submitId;
}

final class TaskStatusChanged extends TaskEvent {
  const TaskStatusChanged(this.task);
  final TaskRecord task;
}

/// `task.error`: the submit or cancel was refused. [submitId] correlates with
/// the submit frame when the engine echoed it.
final class TaskRejected extends TaskEvent {
  const TaskRejected({
    required this.error,
    this.submitId,
    this.taskId,
    this.clientMsgUuid,
  });
  final String error;
  final String? submitId;
  final String? taskId;
  final String? clientMsgUuid;
}

final class TaskDelta extends TaskEvent {
  const TaskDelta({required this.taskId, required this.delta, this.threadUuid});
  final String taskId;
  final String delta;
  final String? threadUuid;
}

final class TaskChatDone extends TaskEvent {
  const TaskChatDone({required this.taskId, this.threadUuid});
  final String taskId;
  final String? threadUuid;
}

final class TaskChatError extends TaskEvent {
  const TaskChatError({required this.taskId, required this.error});
  final String taskId;
  final String error;
}

final class TaskChatCancelled extends TaskEvent {
  const TaskChatCancelled({required this.taskId});
  final String taskId;
}

final class ThreadSubscribed extends TaskEvent {
  const ThreadSubscribed(this.threadUuid);
  final String threadUuid;
}

/// `tool.approval.request`, possibly for a tool exported by a hive peer.
final class ToolApprovalRequested extends TaskEvent {
  const ToolApprovalRequested(this.request, {this.taskId});
  final ToolApprovalRequest request;
  final String? taskId;
}

/// `tool.approval.resolved`: another UI answered, so dismiss the prompt.
final class ToolApprovalResolved extends TaskEvent {
  const ToolApprovalResolved({required this.approvalId, this.decision, this.taskId});
  final String approvalId;
  final String? decision;
  final String? taskId;
}

/// `oauth.request`: a tool needs the user to sign in through a browser.
final class OAuthRequested extends TaskEvent {
  const OAuthRequested(this.authorization, {this.taskId});
  final OAuthAuthorization authorization;
  final String? taskId;
}

/// `oauth.resolved`: the sign-in finished (or gave up), dismiss the prompt.
final class OAuthResolved extends TaskEvent {
  const OAuthResolved({
    required this.authId,
    required this.toolUuid,
    required this.status,
    this.taskId,
  });
  final String authId;
  final String toolUuid;
  final OAuthStatus status;
  final String? taskId;
}

/// Parses [frame] into a [TaskEvent], or null when it is not task related or
/// is malformed.
TaskEvent? parseTaskEvent(WireFrame frame) {
  final Map<String, dynamic> data = frame.data ?? const <String, dynamic>{};
  switch (frame.type) {
    case 'task.accepted':
      final TaskRecord? task = TaskRecord.tryParse(data);
      return task == null ? null : TaskAccepted(task, submitId: frame.id);
    case 'task.status':
      final TaskRecord? task = TaskRecord.tryParse(data);
      return task == null ? null : TaskStatusChanged(task);
    case 'task.error':
      final Object? message = data['error'];
      return TaskRejected(
        error: message is String && message.isNotEmpty
            ? message
            : 'The task was refused.',
        submitId: frame.id,
        taskId: data['task_id'] is String ? data['task_id'] as String : null,
        clientMsgUuid: data['client_msg_uuid'] is String
            ? data['client_msg_uuid'] as String
            : null,
      );
    case 'thread.subscribed':
      final Object? thread = data['thread_uuid'];
      return thread is String ? ThreadSubscribed(thread) : null;
    case 'chat.delta':
      final String? id = frame.id;
      final Object? delta = data['delta'];
      if (id == null || delta is! String) return null;
      return TaskDelta(
        taskId: id,
        delta: delta,
        threadUuid: data['thread_uuid'] is String
            ? data['thread_uuid'] as String
            : null,
      );
    case 'chat.done':
      final String? id = frame.id;
      if (id == null) return null;
      return TaskChatDone(
        taskId: id,
        threadUuid: data['thread_uuid'] is String
            ? data['thread_uuid'] as String
            : null,
      );
    case 'chat.error':
      final String? id = frame.id;
      if (id == null) return null;
      return TaskChatError(
        taskId: id,
        error: data['error'] is String
            ? data['error'] as String
            : 'Chat turn failed.',
      );
    case 'chat.cancelled':
      final String? id = frame.id;
      return id == null ? null : TaskChatCancelled(taskId: id);
    case 'tool.approval.request':
      final String? id = frame.id;
      final Object? arguments = data['arguments'];
      if (id == null ||
          data['approval_id'] is! String ||
          data['tool_name'] is! String ||
          arguments is! Map) {
        return null;
      }
      return ToolApprovalRequested(
        ToolApprovalRequest(
          turnId: id,
          approvalId: data['approval_id'] as String,
          threadUuid: data['thread_uuid'] is String
              ? data['thread_uuid'] as String
              : '',
          toolName: data['tool_name'] as String,
          arguments: arguments.cast<String, dynamic>(),
          operation: data['operation'] is String
              ? data['operation'] as String
              : 'update',
          remote: data['remote'] == true,
          peerName: data['peer_name'] is String
              ? data['peer_name'] as String
              : null,
          peerNodeId: data['peer_node_id'] is String
              ? data['peer_node_id'] as String
              : null,
        ),
        taskId: data['task_id'] is String ? data['task_id'] as String : id,
      );
    case 'oauth.request':
      final OAuthAuthorization? authorization = OAuthAuthorization.tryParseFrame(
        data,
        turnId: frame.id,
      );
      if (authorization == null) return null;
      return OAuthRequested(
        authorization,
        taskId: data['task_id'] is String ? data['task_id'] as String : frame.id,
      );
    case 'oauth.resolved':
      final Object? authId = data['auth_id'];
      final Object? toolUuid = data['tool_uuid'];
      final OAuthStatus? status = OAuthStatus.tryParse(data['status']);
      if (authId is! String || authId.isEmpty || toolUuid is! String || status == null) {
        return null;
      }
      return OAuthResolved(
        authId: authId,
        toolUuid: toolUuid,
        status: status,
        taskId: frame.id,
      );
    case 'tool.approval.resolved':
      final Object? approval = data['approval_id'];
      if (approval is! String) return null;
      return ToolApprovalResolved(
        approvalId: approval,
        decision: data['decision'] is String ? data['decision'] as String : null,
        taskId: frame.id,
      );
  }
  return null;
}

/// Builds the `task.submit` payload (engine `hive/tasks.py::_parse_submit`).
/// Exactly one of [threadUuid] / [workspaceUuid] is required. [executor] is a
/// node id; null runs the task on the connected engine.
Map<String, dynamic> buildTaskSubmitData({
  required String content,
  String? threadUuid,
  String? workspaceUuid,
  String? clientMsgUuid,
  String? executor,
  String? modelId,
  ChatFileContext? fileContext,
}) {
  if ((threadUuid == null) == (workspaceUuid == null)) {
    throw ArgumentError('Exactly one of threadUuid or workspaceUuid is required.');
  }
  if (content.trim().isEmpty) {
    throw ArgumentError('Task content must not be empty.');
  }
  return <String, dynamic>{
    'content': content,
    'thread_uuid': ?threadUuid,
    'workspace_uuid': ?workspaceUuid,
    'client_msg_uuid': ?clientMsgUuid,
    'executor': ?executor,
    'model_id': ?modelId,
    if (fileContext != null && !fileContext.isEmpty)
      'file_context': fileContext.toJson(),
    if (workspaceUuid != null) 'new_thread': true,
  };
}
