import 'dart:async';

import '../repositories/engine_repository.dart';

enum ChatSessionStatus { idle, connecting, streaming, completed, failed }

final class ChatSessionState {
  const ChatSessionState({this.status = ChatSessionStatus.idle, this.text = '', this.error});
  final ChatSessionStatus status;
  final String text;
  final Object? error;
}

final class ChatSessionController {
  ChatSessionController({required this.repository});
  final EngineRepository repository;
  final StreamController<ChatSessionState> _states = StreamController<ChatSessionState>.broadcast();
  ChatSessionState _state = const ChatSessionState();
  bool _closed = false;

  ChatSessionState get state => _state;
  Stream<ChatSessionState> get states => _states.stream;

  Future<void> send({required String content, String? threadUuid, String? workspaceUuid, String? modelId}) async {
    _emit(const ChatSessionState(status: ChatSessionStatus.streaming));
    final StringBuffer response = StringBuffer();
    try {
      await for (final String delta in repository.streamChat(content: content, threadUuid: threadUuid, workspaceUuid: workspaceUuid, modelId: modelId)) {
        response.write(delta);
        _emit(ChatSessionState(status: ChatSessionStatus.streaming, text: response.toString()));
      }
      _emit(ChatSessionState(status: ChatSessionStatus.completed, text: response.toString()));
    } on Object catch (error) {
      _emit(ChatSessionState(status: ChatSessionStatus.failed, text: response.toString(), error: error));
    }
  }

  Future<void> close() async {
    _closed = true;
    await _states.close();
  }

  void _emit(ChatSessionState state) {
    _state = state;
    if (!_closed) _states.add(state);
  }
}
