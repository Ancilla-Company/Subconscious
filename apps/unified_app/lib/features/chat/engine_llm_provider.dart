import 'package:core_business_logic/core_business_logic.dart' as core;
import 'package:flutter/foundation.dart';

enum EngineChatMessageOrigin { user, assistant }

final class EngineChatMessage {
  EngineChatMessage.user(String text)
    : origin = EngineChatMessageOrigin.user,
      _text = text;

  EngineChatMessage.assistant([String text = ''])
    : origin = EngineChatMessageOrigin.assistant,
      _text = text;

  final EngineChatMessageOrigin origin;
  String _text;

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

  Stream<String> sendMessageStream(String prompt) async* {
    final EngineChatMessage user = EngineChatMessage.user(prompt);
    _history.add(user);
    _timestamps[user] = DateTime.now();
    final EngineChatMessage response = EngineChatMessage.assistant();
    _history.add(response);
    _timestamps[response] = DateTime.now();
    notifyListeners();
    try {
      await for (final String delta in _stream(prompt)) {
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

  Stream<String> _stream(String prompt) => repository.streamChat(
    content: prompt,
    threadUuid: threadUuid,
    workspaceUuid: workspaceUuid,
    modelId: modelId,
  );
}
