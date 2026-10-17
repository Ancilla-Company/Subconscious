import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../api/engine_socket.dart';
import '../models/engine_models.dart';

/// Events of a realtime voice session (`realtime.*` frames from the engine).
sealed class RealtimeEvent {
  const RealtimeEvent();
}

final class RealtimeStarted extends RealtimeEvent {
  const RealtimeStarted({this.threadUuid, this.sampleRate = 24000});
  final String? threadUuid;
  final int sampleRate;
}

/// PCM16 mono audio spoken by the model.
final class RealtimeAudio extends RealtimeEvent {
  const RealtimeAudio(this.pcm);
  final Uint8List pcm;
}

final class RealtimeTranscript extends RealtimeEvent {
  const RealtimeTranscript({
    required this.role,
    required this.text,
    required this.isFinal,
  });
  final String role;
  final String text;
  final bool isFinal;
}

/// The user started talking: playback of the model's speech should stop.
final class RealtimeSpeechStarted extends RealtimeEvent {
  const RealtimeSpeechStarted();
}

final class RealtimeToolActivity extends RealtimeEvent {
  const RealtimeToolActivity({required this.name, required this.status});
  final String name;
  final String status;
}

/// The session created a thread (voice started from a workspace draft).
final class RealtimeThreadCreated extends RealtimeEvent {
  const RealtimeThreadCreated(this.threadUuid);
  final String threadUuid;
}

final class RealtimeFailed extends RealtimeEvent {
  const RealtimeFailed(this.message);
  final String message;
}

final class RealtimeStopped extends RealtimeEvent {
  const RealtimeStopped();
}

/// One realtime speech-to-speech session over the engine socket.
///
/// The engine owns the provider connection and function calling. Requests that
/// need files or tools run through the normal agent graph there, so this class
/// only moves audio and reports events.
final class RealtimeSession {
  RealtimeSession(this._socket);

  final EngineSocket _socket;
  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast();
  StreamSubscription<WireFrame>? _subscription;
  String? _frameId;
  bool _closed = false;

  Stream<RealtimeEvent> get events => _events.stream;
  bool get isActive => _frameId != null && !_closed;

  /// Starts a session with exactly one of [threadUuid] or [workspaceUuid].
  void start({
    required String modelId,
    String? threadUuid,
    String? workspaceUuid,
    String? agentModelId,
  }) {
    if (_frameId != null) throw StateError('The session was already started.');
    _subscription = _socket.frames.listen(_onFrame);
    _frameId = _socket.send(
      type: 'realtime.start',
      data: <String, dynamic>{
        'model_id': modelId,
        if (threadUuid != null) 'thread_uuid': threadUuid,
        if (workspaceUuid != null) 'workspace_uuid': workspaceUuid,
        if (agentModelId != null) 'agent_model_id': agentModelId,
      },
    );
  }

  void sendAudio(Uint8List pcm16) {
    if (!isActive || pcm16.isEmpty) return;
    _socket.send(
      type: 'realtime.audio',
      data: <String, dynamic>{'audio': base64Encode(pcm16)},
    );
  }

  void interrupt() {
    if (isActive) _socket.send(type: 'realtime.interrupt');
  }

  Future<void> stop() async {
    if (_frameId != null && !_closed) _socket.send(type: 'realtime.stop');
    await _close();
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    if (!_events.isClosed) await _events.close();
  }

  void _onFrame(WireFrame frame) {
    if (!frame.type.startsWith('realtime.') || frame.id != _frameId) return;
    final Map<String, dynamic> data = frame.data ?? const <String, dynamic>{};
    final RealtimeEvent? event = switch (frame.type) {
      'realtime.started' => RealtimeStarted(
        threadUuid: data['thread_uuid'] as String?,
        sampleRate: (data['sample_rate'] as num?)?.toInt() ?? 24000,
      ),
      'realtime.audio' when data['audio'] is String => RealtimeAudio(
        base64Decode(data['audio'] as String),
      ),
      'realtime.transcript' => RealtimeTranscript(
        role: data['role'] as String? ?? 'assistant',
        text: data['text'] as String? ?? '',
        isFinal: data['final'] as bool? ?? false,
      ),
      'realtime.speech_started' => const RealtimeSpeechStarted(),
      'realtime.tool' => RealtimeToolActivity(
        name: data['name'] as String? ?? '',
        status: data['status'] as String? ?? '',
      ),
      'realtime.thread' when data['thread_uuid'] is String =>
        RealtimeThreadCreated(data['thread_uuid'] as String),
      'realtime.error' => RealtimeFailed(
        data['error'] as String? ?? 'Realtime error.',
      ),
      'realtime.stopped' => const RealtimeStopped(),
      _ => null,
    };
    if (event == null || _events.isClosed) return;
    if (event is RealtimeStarted) _hasStarted = true;
    _events.add(event);
    // A failure before the session started ends it; later errors are advisory.
    if (event is RealtimeStopped || (event is RealtimeFailed && !_hasStarted)) {
      unawaited(_close());
    }
  }

  bool _hasStarted = false;
}
