import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

import 'wav.dart';

/// Microphone access as PCM16 mono, so recordings and realtime share one path.
abstract interface class MicCapture {
  Future<bool> ensurePermission();

  /// Starts capturing at [sampleRate]; the stream ends after [stop].
  Future<Stream<Uint8List>> start({required int sampleRate});
  Future<void> stop();
  Future<void> dispose();
}

/// Plays a finished clip and completes when it ends or is stopped.
abstract interface class ClipPlayer {
  Future<void> play(Uint8List bytes, String mediaType);
  Future<void> stop();
  Future<void> dispose();
}

final class RecordMicCapture implements MicCapture {
  final AudioRecorder _recorder = AudioRecorder();

  @override
  Future<bool> ensurePermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start({required int sampleRate}) =>
      _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
          // Keeps the model from hearing its own voice through the speakers.
          echoCancel: true,
          noiseSuppress: true,
        ),
      );

  @override
  Future<void> stop() async {
    if (await _recorder.isRecording()) await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

final class AudioPlayersClipPlayer implements ClipPlayer {
  final AudioPlayer _player = AudioPlayer();
  Completer<void>? _playing;

  @override
  Future<void> play(Uint8List bytes, String mediaType) async {
    final Completer<void> finished = Completer<void>();
    _playing = finished;
    final StreamSubscription<void> done = _player.onPlayerComplete.listen((_) {
      if (!finished.isCompleted) finished.complete();
    });
    try {
      await _player.play(BytesSource(bytes, mimeType: mediaType));
      await finished.future;
    } finally {
      await done.cancel();
      if (identical(_playing, finished)) _playing = null;
    }
  }

  @override
  Future<void> stop() async {
    final Completer<void>? playing = _playing;
    await _player.stop();
    if (playing != null && !playing.isCompleted) playing.complete();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}

/// Plays a stream of PCM16 chunks (the realtime model's voice) with a player
/// that only takes whole clips: chunks are batched into short WAV clips that
/// play back to back. A new user utterance clears whatever is still queued.
final class PcmStreamPlayer {
  PcmStreamPlayer(
    this._player, {
    this.sampleRate = 24000,
    this.batch = const Duration(milliseconds: 300),
    this.flushAfter = const Duration(milliseconds: 120),
  });

  final ClipPlayer _player;
  final int sampleRate;
  final Duration batch;
  final Duration flushAfter;

  final BytesBuilder _pending = BytesBuilder(copy: false);
  Timer? _flushTimer;
  Future<void> _tail = Future<void>.value();
  int _generation = 0;

  int get _batchBytes => sampleRate * 2 * batch.inMilliseconds ~/ 1000;

  void add(Uint8List pcm) {
    _pending.add(pcm);
    if (_pending.length >= _batchBytes) {
      flush();
    } else {
      _flushTimer?.cancel();
      _flushTimer = Timer(flushAfter, flush);
    }
  }

  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty) return;
    final Uint8List wav = pcm16ToWav(
      _pending.takeBytes(),
      sampleRate: sampleRate,
    );
    final int generation = _generation;
    _tail = _tail.then((_) async {
      if (generation != _generation) return;
      try {
        await _player.play(wav, 'audio/wav');
      } on Object {
        // A failed clip should not stop the ones after it.
      }
    });
  }

  /// Drops queued audio and stops the clip that is playing.
  Future<void> clear() async {
    _generation++;
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    await _player.stop();
  }

  Future<void> dispose() async {
    await clear();
    await _player.dispose();
  }
}
