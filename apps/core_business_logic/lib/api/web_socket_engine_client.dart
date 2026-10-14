import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/engine_models.dart';
import 'engine_socket.dart';
import 'task_socket_mixin.dart';

final class WebSocketEngineClient with TaskSocketMixin implements EngineSocket {
  WebSocketEngineClient({required this.endpoint});
  final Uri endpoint;
  final StreamController<WireFrame> _frames =
      StreamController<WireFrame>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Completer<void>? _hello;
  int _sequence = 0;
  bool _closing = false;

  @override
  Stream<WireFrame> get frames => _frames.stream;
  @override
  bool get isConnected => _channel != null;

  @override
  Future<void> connect() async {
    if (isConnected) return;
    final WebSocketChannel channel = WebSocketChannel.connect(endpoint);
    _channel = channel;
    _hello = Completer<void>();
    _closing = false;
    try {
      await channel.ready;
      _subscription = channel.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      send(type: 'client.hello', data: <String, dynamic>{});
      await _hello!.future.timeout(const Duration(seconds: 10));
    } on Object {
      await _disconnect();
      rethrow;
    }
  }

  @override
  String send({required String type, Map<String, dynamic>? data, String? id}) {
    final WebSocketChannel? channel = _channel;
    if (channel == null)
      throw StateError('The engine WebSocket is not connected.');
    final String frameId = id ?? 'dart-${_sequence++}';
    final WireFrame frame = WireFrame(type: type, id: frameId, data: data);
    channel.sink.add(frame.encode());
    return frameId;
  }

  @override
  String sendChat({
    required String content,
    String? threadUuid,
    String? workspaceUuid,
    String? modelId,
    ChatFileContext? fileContext,
  }) {
    if ((threadUuid == null) == (workspaceUuid == null)) {
      throw ArgumentError(
        'Exactly one of threadUuid or workspaceUuid is required.',
      );
    }
    return send(
      type: 'chat.send',
      data: <String, dynamic>{
        'content': content,
        if (threadUuid != null) 'thread_uuid': threadUuid,
        if (workspaceUuid != null) 'workspace_uuid': workspaceUuid,
        if (modelId != null) 'model_id': modelId,
        if (fileContext != null && !fileContext.isEmpty)
          'file_context': fileContext.toJson(),
      },
    );
  }

  @override
  void registerUiTools() => send(
    type: 'tool.register',
    data: <String, dynamic>{
      'tools': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'set_ui_theme_color'},
        <String, dynamic>{'id': 'set_ui_lighting_mode'},
        <String, dynamic>{'id': 'open_ui_workspace_file'},
        <String, dynamic>{'id': 'navigate_ui'},
        <String, dynamic>{'id': 'set_workspace_builtin_tool_enabled'},
      ],
    },
  );

  @override
  void respondToolApproval({
    required String turnId,
    required String approvalId,
    required bool approved,
  }) => send(
    type: 'tool.approval.response',
    id: turnId,
    data: <String, dynamic>{
      'approval_id': approvalId,
      'decision': approved ? 'approve' : 'deny',
    },
  );

  @override
  void sendClientToolResult({
    required String turnId,
    required String requestId,
    required bool ok,
    Object? result,
    String? error,
  }) => send(
    type: 'client.tool.result',
    id: turnId,
    data: <String, dynamic>{
      'request_id': requestId,
      'ok': ok,
      if (ok) 'result': result,
      if (!ok) 'error': error ?? 'The UI tool failed.',
    },
  );

  @override
  void cancelChat(String turnId) => send(
    type: 'chat.cancel',
    id: turnId,
    data: <String, dynamic>{'turn_id': turnId},
  );

  @override
  Future<void> close() => _disconnect();

  @override
  Future<void> dispose() async {
    await _disconnect();
    if (!_frames.isClosed) await _frames.close();
  }

  Future<void> _disconnect() async {
    _closing = true;
    final StreamSubscription<Object?>? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final WebSocketChannel? channel = _channel;
    _channel = null;
    await channel?.sink.close();
    _hello = null;
  }

  void _onMessage(Object? raw) {
    try {
      final WireFrame frame = WireFrame.decode(raw.toString());
      if (frame.type == 'client.hello.ack' && !(_hello?.isCompleted ?? true))
        _hello!.complete();
      if (frame.type == 'client.hello.reject' && !(_hello?.isCompleted ?? true))
        _hello!.completeError(
          StateError(
            frame.data?['reason'] as String? ?? 'Engine rejected client.hello.',
          ),
        );
      if (!_frames.isClosed) _frames.add(frame);
    } on Object catch (error, stackTrace) {
      if (!_frames.isClosed) _frames.addError(error, stackTrace);
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (!(_hello?.isCompleted ?? true))
      _hello!.completeError(error, stackTrace);
    if (!_frames.isClosed) _frames.addError(error, stackTrace);
  }

  void _onDone() {
    _channel = null;
    if (!_closing && !(_hello?.isCompleted ?? true))
      _hello!.completeError(
        StateError('Engine WebSocket closed during handshake.'),
      );
  }
}
