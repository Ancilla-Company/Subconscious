import 'dart:async';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

import 'voice_io.dart';
import 'wav.dart';

enum DictationState { idle, recording, transcribing }

enum RealtimeState { off, connecting, live }

/// One line of a realtime conversation, for the live caption.
final class VoiceLine {
  const VoiceLine({required this.role, required this.text});
  final String role;
  final String text;
}

/// Voice features of one chat panel: dictating a prompt, reading a reply
/// aloud and a realtime speech-to-speech conversation.
///
/// What is offered comes from the capabilities the engine reports for the
/// configured models, never from hard-coded model names.
final class VoiceController extends ChangeNotifier {
  VoiceController({
    required EngineRepository Function() repository,
    MicCapture Function()? micFactory,
    ClipPlayer Function()? playerFactory,
  }) : _repository = repository,
       _micFactory = micFactory ?? RecordMicCapture.new,
       _playerFactory = playerFactory ?? AudioPlayersClipPlayer.new;

  final EngineRepository Function() _repository;
  final MicCapture Function() _micFactory;
  final ClipPlayer Function() _playerFactory;

  List<ModelInfo> _models = const <ModelInfo>[];

  /// Called with a short message when something fails.
  void Function(String message)? onError;

  // ---- what is available --------------------------------------------------

  set models(List<ModelInfo> value) {
    _models = value;
    notifyListeners();
  }

  ModelInfo? _first(bool Function(ModelCapabilities) test) {
    for (final ModelInfo model in _models) {
      final ModelCapabilities? capabilities = model.capabilities;
      if (capabilities != null && test(capabilities)) return model;
    }
    return null;
  }

  ModelInfo? get transcriptionModel =>
      _first((ModelCapabilities c) => c.canTranscribe);
  ModelInfo? get speechModel => _first((ModelCapabilities c) => c.canSpeak);
  ModelInfo? get realtimeModel =>
      _first((ModelCapabilities c) => c.canRealtime);

  bool get canDictate => transcriptionModel != null;
  bool get canSpeak => speechModel != null;
  bool get canRealtime => realtimeModel != null;

  // ---- dictation ----------------------------------------------------------

  DictationState dictation = DictationState.idle;
  MicCapture? _dictationMic;
  StreamSubscription<Uint8List>? _dictationSubscription;
  final BytesBuilder _dictated = BytesBuilder(copy: false);
  static const int _dictationRate = 16000;

  Future<void> startDictation() async {
    final ModelInfo? model = transcriptionModel;
    if (model == null || dictation != DictationState.idle) return;
    final MicCapture mic = _micFactory();
    try {
      if (!await mic.ensurePermission()) {
        await mic.dispose();
        _fail('Microphone access was not granted.');
        return;
      }
      _dictated.clear();
      final Stream<Uint8List> pcm = await mic.start(sampleRate: _dictationRate);
      _dictationMic = mic;
      _dictationSubscription = pcm.listen(_dictated.add);
      dictation = DictationState.recording;
      notifyListeners();
    } on Object catch (error) {
      await mic.dispose();
      _fail("Couldn't start recording: $error");
    }
  }

  /// Stops recording and returns the transcript, or null on failure/cancel.
  Future<String?> finishDictation() async {
    final ModelInfo? model = transcriptionModel;
    if (dictation != DictationState.recording || model == null) return null;
    await _releaseDictationMic();
    final Uint8List pcm = _dictated.takeBytes();
    if (pcm.isEmpty) {
      dictation = DictationState.idle;
      notifyListeners();
      return null;
    }
    dictation = DictationState.transcribing;
    notifyListeners();
    try {
      return await _repository().rest.transcribeAudio(
        modelId: model.id,
        audio: pcm16ToWav(pcm, sampleRate: _dictationRate),
        mediaType: 'audio/wav',
      );
    } on Object catch (error) {
      _fail("Couldn't transcribe the recording: $error");
      return null;
    } finally {
      dictation = DictationState.idle;
      notifyListeners();
    }
  }

  Future<void> cancelDictation() async {
    if (dictation != DictationState.recording) return;
    await _releaseDictationMic();
    _dictated.clear();
    dictation = DictationState.idle;
    notifyListeners();
  }

  Future<void> _releaseDictationMic() async {
    await _dictationSubscription?.cancel();
    _dictationSubscription = null;
    final MicCapture? mic = _dictationMic;
    _dictationMic = null;
    if (mic != null) {
      await mic.stop();
      await mic.dispose();
    }
  }

  // ---- read aloud ---------------------------------------------------------

  /// Identifies the message being read, so the UI can show a stop control.
  Object? speakingKey;
  ClipPlayer? _speaker;

  Future<void> toggleSpeak(Object key, String text) async {
    if (speakingKey != null) {
      final bool sameMessage = speakingKey == key;
      await stopSpeaking();
      if (sameMessage) return;
    }
    final ModelInfo? model = speechModel;
    if (model == null || text.trim().isEmpty) return;
    speakingKey = key;
    notifyListeners();
    final ClipPlayer player = _speaker = _playerFactory();
    try {
      final SpeechAudio audio = await _repository().rest.synthesizeSpeech(
        modelId: model.id,
        text: _speakable(text),
      );
      if (!identical(_speaker, player)) return; // stopped while synthesizing
      await player.play(audio.bytes, audio.mediaType);
    } on Object catch (error) {
      if (identical(_speaker, player)) _fail("Couldn't read the reply: $error");
    } finally {
      if (identical(_speaker, player)) {
        _speaker = null;
        speakingKey = null;
        notifyListeners();
      }
      await player.dispose();
    }
  }

  Future<void> stopSpeaking() async {
    final ClipPlayer? player = _speaker;
    _speaker = null;
    speakingKey = null;
    notifyListeners();
    await player?.stop();
  }

  /// The speech API caps input; read the start of very long replies.
  static String _speakable(String text) {
    final String plain = text
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' code omitted. ')
        .replaceAll(RegExp(r'[*_`#>]+'), '')
        .trim();
    return plain.length <= 4000 ? plain : plain.substring(0, 4000);
  }

  // ---- realtime -----------------------------------------------------------

  RealtimeState realtime = RealtimeState.off;
  final List<VoiceLine> lines = <VoiceLine>[];
  String? toolActivity;
  RealtimeSession? _session;
  StreamSubscription<RealtimeEvent>? _sessionSubscription;
  MicCapture? _liveMic;
  StreamSubscription<Uint8List>? _liveMicSubscription;
  PcmStreamPlayer? _livePlayer;

  /// Starts a realtime conversation in [threadUuid]. The engine runs the
  /// model's function calls through the normal agent graph.
  Future<void> startRealtime({
    required String threadUuid,
    String? agentModelId,
  }) async {
    final ModelInfo? model = realtimeModel;
    if (model == null || realtime != RealtimeState.off) return;
    realtime = RealtimeState.connecting;
    lines.clear();
    toolActivity = null;
    notifyListeners();
    final RealtimeSession session = RealtimeSession(_repository().socket);
    _session = session;
    _sessionSubscription = session.events.listen(_onRealtimeEvent);
    try {
      session.start(
        modelId: model.id,
        threadUuid: threadUuid,
        agentModelId: agentModelId,
      );
    } on Object catch (error) {
      await _endRealtime();
      _fail("Couldn't start the voice session: $error");
    }
  }

  Future<void> stopRealtime() async {
    final RealtimeSession? session = _session;
    await _endRealtime();
    await session?.stop();
  }

  Future<void> _onRealtimeEvent(RealtimeEvent event) async {
    switch (event) {
      case RealtimeStarted():
        await _startLiveAudio(event.sampleRate);
      case RealtimeAudio():
        _livePlayer?.add(event.pcm);
      case RealtimeSpeechStarted():
        await _livePlayer?.clear();
      case RealtimeTranscript():
        if (event.isFinal && event.text.trim().isNotEmpty) {
          lines.add(VoiceLine(role: event.role, text: event.text.trim()));
          notifyListeners();
        }
      case RealtimeToolActivity():
        toolActivity = event.status == 'started' ? event.name : null;
        notifyListeners();
      case RealtimeThreadCreated():
        break;
      case RealtimeFailed():
        _fail(event.message);
      case RealtimeStopped():
        await _endRealtime();
    }
  }

  Future<void> _startLiveAudio(int sampleRate) async {
    if (realtime != RealtimeState.connecting) return;
    final MicCapture mic = _micFactory();
    try {
      if (!await mic.ensurePermission()) {
        await mic.dispose();
        _fail('Microphone access was not granted.');
        await stopRealtime();
        return;
      }
      _livePlayer = PcmStreamPlayer(_playerFactory(), sampleRate: sampleRate);
      final Stream<Uint8List> pcm = await mic.start(sampleRate: sampleRate);
      _liveMic = mic;
      _liveMicSubscription = pcm.listen((Uint8List chunk) {
        _session?.sendAudio(chunk);
      });
      realtime = RealtimeState.live;
      notifyListeners();
    } on Object catch (error) {
      await mic.dispose();
      _fail("Couldn't start the microphone: $error");
      await stopRealtime();
    }
  }

  Future<void> _endRealtime() async {
    _session = null;
    final StreamSubscription<RealtimeEvent>? events = _sessionSubscription;
    _sessionSubscription = null;
    await _liveMicSubscription?.cancel();
    _liveMicSubscription = null;
    final MicCapture? mic = _liveMic;
    _liveMic = null;
    if (mic != null) {
      await mic.stop();
      await mic.dispose();
    }
    final PcmStreamPlayer? player = _livePlayer;
    _livePlayer = null;
    await player?.dispose();
    toolActivity = null;
    realtime = RealtimeState.off;
    notifyListeners();
    await events?.cancel();
  }

  void _fail(String message) {
    onError?.call(message);
  }

  bool _disposed = false;

  // Cleanup after dispose is asynchronous and still reports state changes.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    unawaited(cancelDictation());
    unawaited(stopSpeaking());
    unawaited(stopRealtime());
    _disposed = true;
    super.dispose();
  }
}
