import 'dart:async';

import '../api/engine_socket.dart';
import '../api/task_socket_mixin.dart';
import '../models/engine_models.dart';
import 'channel_codec.dart';
import 'peer_link.dart';

/// [EngineSocket] over an authenticated peer link. Existing frame types
/// travel unchanged (webrtc.md 6.2); frames go over `control`, inbound frames
/// from `control` and `events` become [WireFrame]s.
final class PeerEngineSocket with TaskSocketMixin implements EngineSocket {
  PeerEngineSocket({
    required this.linkProvider,
    this.helloTimeout = const Duration(seconds: 10),
  });

  /// Returns an open link (connecting if necessary).
  final Future<PeerLink> Function() linkProvider;
  final Duration helloTimeout;

  final StreamController<WireFrame> _frames =
      StreamController<WireFrame>.broadcast();
  PeerLink? _link;
  StreamSubscription<InboundEnvelope>? _subscription;
  Completer<void>? _hello;
  int _sequence = 0;

  @override
  Stream<WireFrame> get frames => _frames.stream;

  @override
  bool get isConnected => (_link?.isOpen ?? false) && _subscription != null;

  @override
  Future<void> connect() async {
    if (isConnected) return;
    final PeerLink link = await linkProvider();
    _link = link;
    _hello = Completer<void>();
    _subscription = link.envelopes.listen(_onEnvelope, onDone: _onDone);
    try {
      send(type: 'client.hello', data: <String, dynamic>{});
      await _hello!.future.timeout(helloTimeout);
    } on Object {
      await _detach();
      rethrow;
    }
  }

  @override
  String send({required String type, Map<String, dynamic>? data, String? id}) {
    final PeerLink? link = _link;
    if (link == null || !link.isOpen) {
      throw StateError('The peer connection is not open.');
    }
    final String frameId = id ?? 'dart-${_sequence++}';
    unawaited(
      link
          .send('control', Envelope(type: type, id: frameId, data: data))
          .catchError((Object error, StackTrace stack) {
            if (!_frames.isClosed) _frames.addError(error, stack);
          }),
    );
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

  /// Detaches from the link without closing it: the link is shared with the
  /// REST tunnel and is owned by whoever created it.
  @override
  Future<void> close() => _detach();

  @override
  Future<void> dispose() async {
    await _detach();
    if (!_frames.isClosed) await _frames.close();
  }

  Future<void> _detach() async {
    final StreamSubscription<InboundEnvelope>? subscription = _subscription;
    _subscription = null;
    _link = null;
    _hello = null;
    await subscription?.cancel();
  }

  void _onEnvelope(InboundEnvelope inbound) {
    if (inbound.channel != 'control' && inbound.channel != 'events') return;
    final Envelope envelope = inbound.envelope;
    final WireFrame frame = WireFrame(
      type: envelope.type,
      id: envelope.id,
      data: envelope.dataMap,
    );
    final Completer<void>? hello = _hello;
    if (hello != null && !hello.isCompleted) {
      if (frame.type == 'client.hello.ack') hello.complete();
      if (frame.type == 'client.hello.reject') {
        hello.completeError(
          StateError(
            frame.data?['reason'] as String? ?? 'Engine rejected client.hello.',
          ),
        );
      }
    }
    if (!_frames.isClosed) _frames.add(frame);
  }

  void _onDone() {
    final Completer<void>? hello = _hello;
    if (hello != null && !hello.isCompleted) {
      hello.completeError(StateError('Peer link closed during handshake.'));
    }
    _link = null;
  }
}
