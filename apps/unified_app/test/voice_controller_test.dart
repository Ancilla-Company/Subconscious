import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/voice/voice_controller.dart';
import 'package:unified_app/features/voice/voice_io.dart';
import 'package:unified_app/features/voice/wav.dart';

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

  void receive(String type, [Map<String, dynamic>? data]) =>
      controller.add(WireFrame(type: type, id: sent.first.id, data: data));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeMic implements MicCapture {
  final StreamController<Uint8List> pcm = StreamController<Uint8List>();
  int? sampleRate;
  bool stopped = false;
  bool granted = true;

  @override
  Future<bool> ensurePermission() async => granted;

  @override
  Future<Stream<Uint8List>> start({required int sampleRate}) async {
    this.sampleRate = sampleRate;
    return pcm.stream;
  }

  @override
  Future<void> stop() async => stopped = true;

  @override
  Future<void> dispose() async {}
}

final class _FakePlayer implements ClipPlayer {
  final List<Uint8List> played = <Uint8List>[];
  final List<String> mediaTypes = <String>[];
  Completer<void>? holding;
  int stops = 0;

  @override
  Future<void> play(Uint8List bytes, String mediaType) async {
    played.add(bytes);
    mediaTypes.add(mediaType);
    final Completer<void>? hold = holding;
    if (hold != null) await hold.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    final Completer<void>? hold = holding;
    if (hold != null && !hold.isCompleted) hold.complete();
  }

  @override
  Future<void> dispose() async {}
}

ModelInfo model(String id, ModelCapabilities capabilities) => ModelInfo(
  id: id,
  name: id,
  provider: 'openai',
  capabilities: capabilities,
);

EngineRepository repositoryFor(
  _FakeSocket socket,
  Future<http.Response> Function(http.Request) handler,
) => EngineRepository(
  rest: RestEngineClient(
    baseUri: Uri.parse('http://engine/api/v1/'),
    token: 't',
    client: MockClient(handler),
  ),
  socket: socket,
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('features appear only when a configured model has the capability', () {
    final VoiceController voice = VoiceController(
      repository: () => throw UnimplementedError(),
    );
    expect(voice.canDictate || voice.canSpeak || voice.canRealtime, isFalse);
    voice.models = <ModelInfo>[
      model('chat', const ModelCapabilities(chat: true)),
      model('asr', const ModelCapabilities(speechToText: true, chat: false)),
    ];
    expect(voice.canDictate, isTrue);
    expect(voice.canSpeak, isFalse);
    expect(voice.canRealtime, isFalse);
    expect(voice.transcriptionModel!.id, 'asr');
    voice.models = <ModelInfo>[
      model('rt', const ModelCapabilities(realtime: true)),
      model('tts', const ModelCapabilities(textToSpeech: true)),
    ];
    expect(voice.canDictate, isFalse);
    expect(voice.canSpeak && voice.canRealtime, isTrue);
  });

  test('dictation records PCM, uploads it as WAV and returns the transcript', () async {
    final _FakeMic mic = _FakeMic();
    http.Request? upload;
    final VoiceController voice = VoiceController(
      repository: () => repositoryFor(_FakeSocket(), (http.Request request) async {
        upload = request;
        return http.Response(jsonEncode(<String, String>{'text': 'hello there'}), 200);
      }),
      micFactory: () => mic,
    )..models = <ModelInfo>[
        model('asr', const ModelCapabilities(speechToText: true)),
      ];

    await voice.startDictation();
    expect(voice.dictation, DictationState.recording);
    expect(mic.sampleRate, 16000);
    mic.pcm.add(Uint8List.fromList(<int>[1, 0, 2, 0]));
    await settle();
    final String? text = await voice.finishDictation();

    expect(text, 'hello there');
    expect(voice.dictation, DictationState.idle);
    expect(mic.stopped, isTrue);
    expect(upload!.url.path, '/api/v1/audio/transcriptions');
    expect(upload!.url.queryParameters['modelId'], 'asr');
    expect(upload!.headers['Content-Type'], 'audio/wav');
    expect(upload!.headers['Authorization'], 'Bearer t');
    expect(String.fromCharCodes(upload!.bodyBytes.sublist(0, 4)), 'RIFF');
    expect(upload!.bodyBytes.sublist(44), <int>[1, 0, 2, 0]);
  });

  test('a denied microphone reports instead of recording', () async {
    final _FakeMic mic = _FakeMic()..granted = false;
    final List<String> errors = <String>[];
    final VoiceController voice = VoiceController(
      repository: () => throw UnimplementedError(),
      micFactory: () => mic,
    )
      ..onError = errors.add
      ..models = <ModelInfo>[
        model('asr', const ModelCapabilities(speechToText: true)),
      ];
    await voice.startDictation();
    expect(voice.dictation, DictationState.idle);
    expect(errors.single, contains('Microphone'));
  });

  test('read aloud synthesizes the reply and toggles off when tapped again', () async {
    final _FakePlayer player = _FakePlayer()..holding = Completer<void>();
    http.Request? request;
    final VoiceController voice = VoiceController(
      repository: () => repositoryFor(_FakeSocket(), (http.Request r) async {
        request = r;
        return http.Response.bytes(
          <int>[7, 7],
          200,
          headers: <String, String>{'content-type': 'audio/mpeg'},
        );
      }),
      playerFactory: () => player,
    )..models = <ModelInfo>[
        model('tts', const ModelCapabilities(textToSpeech: true)),
      ];

    final Future<void> speaking = voice.toggleSpeak('m1', 'Hello **world**');
    await settle();
    expect(voice.speakingKey, 'm1');
    expect(player.played.single, <int>[7, 7]);
    expect(player.mediaTypes.single, 'audio/mpeg');
    final Map<String, dynamic> body =
        jsonDecode(request!.body) as Map<String, dynamic>;
    expect(body['modelId'], 'tts');
    expect(body['input'], 'Hello world');

    await voice.toggleSpeak('m1', 'Hello **world**'); // tap again to stop
    await speaking;
    expect(voice.speakingKey, isNull);
    expect(player.stops, greaterThan(0));
  });

  test('realtime: audio flows both ways and the model voice is cut on barge-in', () async {
    final _FakeSocket socket = _FakeSocket();
    final _FakeMic mic = _FakeMic();
    final _FakePlayer player = _FakePlayer();
    final VoiceController voice = VoiceController(
      repository: () => repositoryFor(socket, (_) async => http.Response('', 404)),
      micFactory: () => mic,
      playerFactory: () => player,
    )..models = <ModelInfo>[
        model('rt', const ModelCapabilities(realtime: true)),
      ];

    await voice.startRealtime(threadUuid: 'th1', agentModelId: 'chat');
    expect(voice.realtime, RealtimeState.connecting);
    expect(socket.sent.single.type, 'realtime.start');
    expect(socket.sent.single.data, <String, dynamic>{
      'model_id': 'rt',
      'thread_uuid': 'th1',
      'agent_model_id': 'chat',
    });

    socket.receive('realtime.started', <String, dynamic>{'sample_rate': 24000});
    await settle();
    expect(voice.realtime, RealtimeState.live);
    expect(mic.sampleRate, 24000);

    mic.pcm.add(Uint8List.fromList(<int>[5, 5]));
    await settle();
    expect(socket.sent.last.type, 'realtime.audio');
    expect(socket.sent.last.data!['audio'], base64Encode(<int>[5, 5]));

    socket.receive('realtime.audio', <String, dynamic>{
      'audio': base64Encode(Uint8List(100)),
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(player.played, hasLength(1)); // batched, flushed as one WAV clip
    expect(player.mediaTypes.single, 'audio/wav');
    expect(player.played.single.length, 44 + 100);

    socket.receive('realtime.transcript', <String, dynamic>{
      'role': 'user',
      'text': 'hi',
      'final': true,
    });
    socket.receive('realtime.speech_started');
    await settle();
    expect(voice.lines.single.text, 'hi');
    expect(player.stops, greaterThan(0));

    socket.receive('realtime.stopped');
    await settle();
    expect(voice.realtime, RealtimeState.off);
    expect(mic.stopped, isTrue);
  });

  test('PCM chunks are batched and cleared playback skips queued clips', () async {
    final _FakePlayer player = _FakePlayer()..holding = Completer<void>();
    final PcmStreamPlayer stream = PcmStreamPlayer(
      player,
      sampleRate: 1000,
      batch: const Duration(milliseconds: 100), // 200 bytes
      flushAfter: const Duration(milliseconds: 30),
    );
    stream.add(Uint8List(200)); // full batch plays immediately and blocks
    await settle();
    stream.add(Uint8List(200)); // queued behind the first
    await settle();
    expect(player.played, hasLength(1));
    await stream.clear(); // drops the queued clip and releases the first
    await settle();
    expect(player.played, hasLength(1));
    stream.add(Uint8List(10)); // a new utterance plays after the flush delay
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(player.played, hasLength(2));
  });

  test('pcm16ToWav writes a canonical header', () {
    final Uint8List wav = pcm16ToWav(
      Uint8List.fromList(<int>[1, 2, 3, 4]),
      sampleRate: 24000,
    );
    final ByteData header = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(header.getUint32(4, Endian.little), 36 + 4);
    expect(header.getUint32(24, Endian.little), 24000);
    expect(header.getUint32(28, Endian.little), 48000);
    expect(header.getUint32(40, Endian.little), 4);
    expect(wav.length, 48);
  });
}
