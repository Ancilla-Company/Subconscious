import 'package:core_business_logic/core_business_logic.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart' as toolkit;

final class EngineLlmProvider extends ChangeNotifier
    implements toolkit.LlmProvider {
  EngineLlmProvider({
    required this.repository,
    this.threadUuid,
    this.workspaceUuid,
    this.modelId,
  });
  final core.EngineRepository repository;
  final String? threadUuid;
  final String? workspaceUuid;
  String? modelId;
  final List<toolkit.ChatMessage> _history = <toolkit.ChatMessage>[];
  final Map<toolkit.ChatMessage, DateTime?> _timestamps =
      <toolkit.ChatMessage, DateTime?>{};

  DateTime? timestampFor(toolkit.ChatMessage message) => _timestamps[message];

  void selectModel(String? value) {
    modelId = value;
    notifyListeners();
  }

  void replaceEngineHistory(Iterable<core.ChatMessage> messages) {
    _history.clear();
    _timestamps.clear();
    for (final core.ChatMessage message in messages) {
      toolkit.ChatMessage? converted;
      switch (message.role.toLowerCase()) {
        case 'user':
          converted = toolkit.ChatMessage.user(
            message.content,
            const <toolkit.Attachment>[],
          );
        case 'assistant':
          final toolkit.ChatMessage response = toolkit.ChatMessage.llm();
          response.append(message.content);
          converted = response;
      }
      if (converted != null) {
        _history.add(converted);
        _timestamps[converted] = message.createdAt;
      }
    }
    notifyListeners();
  }

  @override
  Iterable<toolkit.ChatMessage> get history =>
      List<toolkit.ChatMessage>.unmodifiable(_history);

  @override
  set history(Iterable<toolkit.ChatMessage> value) {
    _history
      ..clear()
      ..addAll(value);
    _timestamps.clear();
    notifyListeners();
  }

  @override
  Stream<String> generateStream(
    String prompt, {
    Iterable<toolkit.Attachment> attachments = const <toolkit.Attachment>[],
  }) async* {
    yield* _stream(prompt);
  }

  @override
  Stream<String> sendMessageStream(
    String prompt, {
    Iterable<toolkit.Attachment> attachments = const <toolkit.Attachment>[],
  }) async* {
    final toolkit.ChatMessage user = toolkit.ChatMessage.user(
      prompt,
      attachments,
    );
    _history.add(user);
    _timestamps[user] = DateTime.now();
    final toolkit.ChatMessage response = toolkit.ChatMessage.llm();
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
