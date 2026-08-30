import '../api/rest_engine_client.dart';
import '../api/web_socket_engine_client.dart';
import '../models/engine_models.dart';

final class EngineRepository {
  const EngineRepository({required this.rest, required this.socket});
  final RestEngineClient rest;
  final WebSocketEngineClient socket;

  Future<void> connect() => socket.connect();
  Future<List<Workspace>> listWorkspaces() => rest.listWorkspaces();
  Future<List<ThreadInfo>> listThreads(String workspaceUuid) => rest.listThreads(workspaceUuid);
  Future<List<ChatMessage>> listMessages(String threadUuid) => rest.listMessages(threadUuid);
  Future<List<ModelInfo>> listModels() => rest.listModels();

  Stream<String> streamChat({required String content, String? threadUuid, String? workspaceUuid, String? modelId}) async* {
    final String turnId = socket.sendChat(content: content, threadUuid: threadUuid, workspaceUuid: workspaceUuid, modelId: modelId);
    const Set<String> terminalFrameTypes = <String>{'chat.delta', 'chat.done', 'chat.error', 'chat.cancelled'};
    await for (final WireFrame frame in socket.frames) {
      if (frame.id != turnId || !terminalFrameTypes.contains(frame.type)) continue;
      final Map<String, dynamic> data = frame.data ?? <String, dynamic>{};
      switch (frame.type) {
        case 'chat.delta':
          final String delta = data['delta'] as String? ?? '';
          if (delta.isNotEmpty) yield delta;
        case 'chat.done':
          return;
        case 'chat.cancelled':
          throw StateError('Chat turn was cancelled.');
        case 'chat.error':
          throw StateError(data['error'] as String? ?? 'Chat turn failed.');
      }
    }
  }
}
