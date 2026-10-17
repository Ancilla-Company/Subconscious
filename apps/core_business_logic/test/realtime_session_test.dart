import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeSocket implements EngineSocket {
  final StreamController<WireFrame> controller =
      StreamController<WireFrame>.broadcast();
  final List<WireFrame> sent = <WireFrame>[];

  @override
  Stream<WireFrame> get frames => controller.stream;

  @override
  String send({required String type, Map<String, dynamic>? data, String? id}) {
    final String frameId = id ?? 'frame-${sent.length + 1}';
    sent.add(WireFrame(type: type, id: frameId, data: data));
    return frameId;
  }

  void receive(String type, String id, [Map<String, dynamic>? data]) =>
      controller.add(WireFrame(type: type, id: id, data: data));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('start sends the model and target, and events map from frames', () async {
    final _FakeSocket socket = _FakeSocket();
    final RealtimeSession session = RealtimeSession(socket);
    final List<RealtimeEvent> events = <RealtimeEvent>[];
    session.events.listen(events.add);

    session.start(
      modelId: 'rt',
      workspaceUuid: 'ws1',
      agentModelId: 'chat',
    );
    final WireFrame start = socket.sent.single;
    expect(start.type, 'realtime.start');
    expect(start.data, <String, dynamic>{
      'model_id': 'rt',
      'workspace_uuid': 'ws1',
      'agent_model_id': 'chat',
    });

    final String id = start.id!;
    socket.receive('realtime.started', id, <String, dynamic>{'sample_rate': 24000});
    socket.receive('realtime.audio', id, <String, dynamic>{
      'audio': base64Encode(<int>[1, 2, 3, 4]),
    });
    socket.receive('realtime.transcript', id, <String, dynamic>{
      'role': 'user',
      'text': 'hello',
      'final': true,
    });
    socket.receive('realtime.speech_started', id);
    socket.receive('realtime.tool', id, <String, dynamic>{
      'name': 'ask_agent',
      'status': 'started',
    });
    socket.receive('realtime.thread', id, <String, dynamic>{'thread_uuid': 't9'});
    // Frames for other ids are ignored.
    socket.receive('realtime.audio', 'other', <String, dynamic>{'audio': 'AAAA'});
    await Future<void>.delayed(Duration.zero);

    expect(events.map((RealtimeEvent e) => e.runtimeType).toList(), <Type>[
      RealtimeStarted,
      RealtimeAudio,
      RealtimeTranscript,
      RealtimeSpeechStarted,
      RealtimeToolActivity,
      RealtimeThreadCreated,
    ]);
    expect((events[1] as RealtimeAudio).pcm, Uint8List.fromList(<int>[1, 2, 3, 4]));
    expect((events[2] as RealtimeTranscript).text, 'hello');
    expect((events[5] as RealtimeThreadCreated).threadUuid, 't9');

    session.sendAudio(Uint8List.fromList(<int>[9, 9]));
    expect(socket.sent.last.type, 'realtime.audio');
    expect(socket.sent.last.data!['audio'], base64Encode(<int>[9, 9]));

    await session.stop();
    expect(socket.sent.last.type, 'realtime.stop');
    expect(session.isActive, isFalse);
  });

  test('a failure before the session starts ends it', () async {
    final _FakeSocket socket = _FakeSocket();
    final RealtimeSession session = RealtimeSession(socket);
    final Future<List<RealtimeEvent>> collected = session.events.toList();
    session.start(modelId: 'rt', threadUuid: 't');
    socket.receive('realtime.error', socket.sent.single.id!, <String, dynamic>{
      'error': 'not supported',
    });
    final List<RealtimeEvent> events = await collected;
    expect((events.single as RealtimeFailed).message, 'not supported');
    expect(session.isActive, isFalse);
  });

  test('model capabilities parse from the engine and gate features', () {
    final ModelInfo stt = ModelInfo.fromJson(<String, dynamic>{
      'id': 'a',
      'name': 'whisper',
      'provider': 'openai',
      'capabilities': <String, dynamic>{
        'speechToText': true,
        'chat': false,
        'sources': <String>['heuristic'],
      },
    });
    expect(stt.capabilities!.canTranscribe, isTrue);
    expect(stt.isChatModel, isFalse);
    expect(stt.capabilities!.canRealtime, isFalse);
    expect(stt.capabilities!.sources, <String>['heuristic']);

    final ModelInfo legacy = ModelInfo.fromJson(<String, dynamic>{
      'id': 'b',
      'name': 'old',
      'provider': 'x',
    });
    expect(legacy.capabilities, isNull);
    expect(legacy.isChatModel, isTrue);
  });
}
