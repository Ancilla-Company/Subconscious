import 'dart:math';

import '../models/client_tool_models.dart';
import '../models/engine_models.dart';
import '../models/task_models.dart';

/// Task frames shared by every [EngineSocket] transport (local WebSocket and
/// peer link): the wire frames are identical (webrtc.md 7.4, 7.5).
mixin TaskSocketMixin {
  Stream<WireFrame> get frames;
  String send({required String type, Map<String, dynamic>? data, String? id});

  /// One `tool.register` frame per group, shared by every transport.
  void registerClientTools(List<ClientToolGroup> groups) {
    for (final ClientToolGroup group in groups) {
      send(type: 'tool.register', data: group.toRegisterData());
    }
  }

  Stream<TaskEvent> get taskEvents => frames
      .map<TaskEvent?>(parseTaskEvent)
      .where((TaskEvent? event) => event != null)
      .cast<TaskEvent>();

  String submitTask({
    required String content,
    String? threadUuid,
    String? workspaceUuid,
    String? clientMsgUuid,
    String? executor,
    String? modelId,
    ChatFileContext? fileContext,
  }) => send(
    type: 'task.submit',
    data: buildTaskSubmitData(
      content: content,
      threadUuid: threadUuid,
      workspaceUuid: workspaceUuid,
      clientMsgUuid: clientMsgUuid ?? newClientMessageId(),
      executor: executor,
      modelId: modelId,
      fileContext: fileContext,
    ),
  );

  void cancelTask(String taskId) => send(
    type: 'task.cancel',
    id: taskId,
    data: <String, dynamic>{'task_id': taskId},
  );

  void subscribeThread(String threadUuid) => send(
    type: 'thread.subscribe',
    data: <String, dynamic>{'thread_uuid': threadUuid},
  );

  void unsubscribeThread(String threadUuid) => send(
    type: 'thread.unsubscribe',
    data: <String, dynamic>{'thread_uuid': threadUuid},
  );
}

/// Random id (<= 64 chars) that makes a submit idempotent across retries.
String newClientMessageId([Random? random]) {
  final Random rng = random ?? Random.secure();
  final StringBuffer out = StringBuffer('cm-');
  for (int i = 0; i < 16; i++) {
    out.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}
