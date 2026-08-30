import 'package:core_business_logic/core_business_logic.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart' as toolkit;

final class EngineLlmProvider extends ChangeNotifier
    implements toolkit.LlmProvider {
  EngineLlmProvider({
    required this.repository,
    this.threadUuid,
    this.workspaceUuid,
  });
  final core.EngineRepository repository;
  final String? threadUuid;
  final String? workspaceUuid;
  final List<toolkit.ChatMessage> _history = <toolkit.ChatMessage>[];

  @override
  Iterable<toolkit.ChatMessage> get history =>
      List<toolkit.ChatMessage>.unmodifiable(_history);

  @override
  set history(Iterable<toolkit.ChatMessage> value) {
    _history
      ..clear()
      ..addAll(value);
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
    _history.add(toolkit.ChatMessage.user(prompt, attachments));
    final toolkit.ChatMessage response = toolkit.ChatMessage.llm();
    _history.add(response);
    notifyListeners();
    try {
      await for (final String delta in _stream(prompt)) {
        response.append(delta);
        notifyListeners();
        yield delta;
      }
    } on Object {
      _history.remove(response);
      notifyListeners();
      rethrow;
    }
  }

  Stream<String> _stream(String prompt) => repository.streamChat(
    content: prompt,
    threadUuid: threadUuid,
    workspaceUuid: workspaceUuid,
  );
}
