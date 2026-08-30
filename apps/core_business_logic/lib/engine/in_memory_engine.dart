import '../models/engine_models.dart';
import 'genkit_model_provider.dart';

/// Small, storage-independent Dart engine core used by the future Shelf host.
/// Persistence and HTTP/WebSocket hosting remain replaceable adapters.
final class InMemoryEngine {
  InMemoryEngine({required this.modelProvider});
  final EngineModelProvider modelProvider;
  final Map<String, List<ChatMessage>> _messagesByThread = <String, List<ChatMessage>>{};

  Stream<String> sendMessage({required String threadUuid, required String content}) async* {
    final List<ChatMessage> history = _messagesByThread.putIfAbsent(threadUuid, () => <ChatMessage>[]);
    history.add(ChatMessage(uuid: _id(), threadUuid: threadUuid, role: 'user', content: content, createdAt: DateTime.now().toUtc()));
    final StringBuffer assistantText = StringBuffer();
    await for (final String delta in modelProvider.generate(history: history, prompt: content)) {
      assistantText.write(delta);
      yield delta;
    }
    history.add(ChatMessage(uuid: _id(), threadUuid: threadUuid, role: 'assistant', content: assistantText.toString(), createdAt: DateTime.now().toUtc()));
  }

  String _id() => DateTime.now().microsecondsSinceEpoch.toString();
}
