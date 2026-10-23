import '../models/client_tool_models.dart';
import '../models/engine_models.dart';
import '../models/task_models.dart';

/// Transport-agnostic engine event socket (local WebSocket or WebRTC channel).
abstract interface class EngineSocket {
  Stream<WireFrame> get frames;
  bool get isConnected;

  Future<void> connect();
  String send({required String type, Map<String, dynamic>? data, String? id});
  String sendChat({
    required String content,
    String? threadUuid,
    String? workspaceUuid,
    String? modelId,
    ChatFileContext? fileContext,
  });
  void registerUiTools();

  /// Sends one schema-bearing `tool.register` frame per group (an empty tool
  /// list removes the group on the engine).
  void registerClientTools(List<ClientToolGroup> groups);
  void respondToolApproval({
    required String turnId,
    required String approvalId,
    required bool approved,
  });
  void sendClientToolResult({
    required String turnId,
    required String requestId,
    required bool ok,
    Object? result,
    String? error,
  });
  void cancelChat(String turnId);

  /// Typed task, chat and approval events derived from [frames].
  Stream<TaskEvent> get taskEvents;

  /// Sends `task.submit`; returns the frame id (echoed by `task.accepted` and
  /// `task.error`). [executor] is a node id, null for the connected engine.
  String submitTask({
    required String content,
    String? threadUuid,
    String? workspaceUuid,
    String? clientMsgUuid,
    String? executor,
    String? modelId,
    ChatFileContext? fileContext,
  });

  /// Sends `task.cancel` for [taskId].
  void cancelTask(String taskId);

  /// Sends `thread.subscribe` / `thread.unsubscribe`.
  void subscribeThread(String threadUuid);
  void unsubscribeThread(String threadUuid);
  Future<void> close();
  Future<void> dispose();
}
