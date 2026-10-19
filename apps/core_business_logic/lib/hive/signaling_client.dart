import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'channel_codec.dart';
import 'hive_api.dart';
import 'identity.dart';
import 'peer_connector.dart';
import 'relay.dart';

const int maxSignalFrameBytes = 64 * 1024;
const Duration signalAuthTimeout = Duration(seconds: 10);
const Duration _stableAfter = Duration(seconds: 30);

/// The slice of a WebSocket used here (fakeable in tests).
abstract interface class SignalSocket {
  Stream<String> get messages;
  void send(String text);
  Future<void> close();
}

typedef SignalConnect = Future<SignalSocket> Function(Uri url);

Future<SignalSocket> connectWebSocket(Uri url) async {
  final WebSocketChannel channel = WebSocketChannel.connect(url);
  await channel.ready;
  return _ChannelSignalSocket(channel);
}

final class _ChannelSignalSocket implements SignalSocket {
  _ChannelSignalSocket(this._channel)
    : messages = _channel.stream.map((Object? raw) {
        if (raw is String) return raw;
        if (raw is List<int>) return utf8.decode(raw, allowMalformed: true);
        return '$raw';
      });
  final WebSocketChannel _channel;
  @override
  final Stream<String> messages;
  @override
  void send(String text) => _channel.sink.add(text);
  @override
  Future<void> close() => _channel.sink.close();
}

/// `https://host/base` becomes `wss://host/base/signal`.
Uri signalUrl(Uri base) => Uri(
  scheme: base.scheme == 'https' ? 'wss' : 'ws',
  host: base.host,
  port: base.hasPort ? base.port : null,
  path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/signal',
);

/// Exponential backoff with full jitter, always within `[base/2, cap]`.
Duration backoffDelay(
  int attempt, {
  Duration base = const Duration(seconds: 1),
  Duration cap = const Duration(seconds: 60),
  double Function()? random,
}) {
  final double rng = (random ?? Random().nextDouble)();
  final double ceiling = min(
    cap.inMilliseconds.toDouble(),
    base.inMilliseconds * pow(2, max(0, min(attempt, 20))).toDouble(),
  );
  return Duration(
    milliseconds: max(base.inMilliseconds / 2, rng * ceiling).round(),
  );
}

final class SignalFrame {
  const SignalFrame(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;
}

/// Signalling WebSocket client: single-use ticket, signed auth, presence,
/// signals, relay frames, ticket refresh and reconnect with backoff.
///
/// Never logs tickets, challenges, SDP or tokens.
final class SignalingClient implements SignalSender, RelaySender {
  SignalingClient({
    required this.api,
    required this.identity,
    SignalConnect? connect,
    this.refreshInterval = const Duration(minutes: 12),
    Future<void> Function(Duration)? sleep,
    double Function()? random,
    this.authTimeout = signalAuthTimeout,
    this.heartbeatInterval = const Duration(seconds: 25),
  }) : _connect = connect ?? connectWebSocket,
       _sleep = sleep ?? Future<void>.delayed,
       _random = random;

  final HiveApi api;
  final NodeIdentity identity;
  final SignalConnect _connect;
  final Duration refreshInterval;
  final Duration authTimeout;

  /// Application-level ping so the server's idle timeout never fires on a
  /// healthy connection (a quiet node would otherwise flap offline).
  final Duration heartbeatInterval;
  final Future<void> Function(Duration) _sleep;
  final double Function()? _random;

  final StreamController<SignalFrame> _frames =
      StreamController<SignalFrame>.broadcast();
  final StreamController<bool> _connection = StreamController<bool>.broadcast();
  SignalSocket? _socket;
  bool _connected = false;
  bool _running = false;
  Completer<void>? _connectedSignal;
  Map<String, dynamic> _presence = <String, dynamic>{
    'clients': <String>[],
    'capabilities': <String, dynamic>{},
  };
  String? hiveId;
  int failures = 0;

  /// Frames received after authentication (presence, signal, relay, ...).
  Stream<SignalFrame> get frames => _frames.stream;
  Stream<bool> get connectionChanges => _connection.stream;
  bool get connected => _connected;

  Future<void> waitConnected(Duration timeout) {
    if (_connected) return Future<void>.value();
    _connectedSignal ??= Completer<void>();
    return _connectedSignal!.future.timeout(timeout);
  }

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_run());
  }

  Future<void> stop() async {
    _running = false;
    await _closeSocket();
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
    await _connection.close();
  }

  void _send(String type, Map<String, dynamic> data) {
    final SignalSocket? socket = _socket;
    if (socket == null || !_connected) {
      throw StateError('Signalling is not connected.');
    }
    final String text = jsonEncode(<String, dynamic>{
      'v': protocolVersion,
      'type': type,
      'data': data,
    });
    if (utf8.encode(text).length > maxSignalFrameBytes) {
      throw ArgumentError('Signalling frame is too large.');
    }
    socket.send(text);
  }

  @override
  Future<void> sendSignal({
    required String sid,
    required String to,
    required String kind,
    required Map<String, dynamic> body,
    String? sig,
  }) async => _send('signal', <String, dynamic>{
    'sid': sid,
    'to': to,
    'kind': kind,
    'body': body,
    'sig': ?sig,
  });

  @override
  Future<void> sendRelay({
    required String sid,
    required String to,
    required Object payload,
  }) async => _send('relay', <String, dynamic>{
    'sid': sid,
    'to': to,
    'payload': payload,
  });

  Future<void> ping() async => _send('ping', <String, dynamic>{});

  Future<void> setPresence({
    List<String> clients = const <String>[],
    Map<String, dynamic> capabilities = const <String, dynamic>{},
  }) async {
    _presence = <String, dynamic>{'clients': clients, 'capabilities': capabilities};
    if (_connected) _send('presence.set', _presence);
  }

  Future<void> _run() async {
    while (_running) {
      final Stopwatch watch = Stopwatch()..start();
      try {
        await _session();
      } on Object {
        // Reconnect on anything transient.
      } finally {
        _setConnected(false);
        await _closeSocket();
      }
      if (!_running) return;
      if (watch.elapsed >= _stableAfter) failures = 0;
      final Duration delay = backoffDelay(failures, random: _random);
      failures++;
      await _sleep(delay);
    }
  }

  Future<void> _session() async {
    final Map<String, dynamic> ticket = await api.signalTicket(identity.nodeId);
    final SignalSocket socket = await _connect(signalUrl(api.baseUri));
    _socket = socket;
    final StreamIterator<String> iterator = StreamIterator<String>(socket.messages);
    try {
      await _sendAuth(socket, ticket, 'auth');
      final Map<String, dynamic> reply = await _next(iterator).timeout(authTimeout);
      if (reply['type'] != 'auth.ok') {
        throw StateError('Signalling authentication was rejected.');
      }
      final Object? data = reply['data'];
      if (data is Map && data['hive_id'] is String) hiveId = data['hive_id'] as String;
      _setConnected(true);
      _send('presence.set', _presence);
      final Timer refresher = Timer.periodic(refreshInterval, (Timer _) {
        unawaited(refreshAuth().catchError((Object _) {}));
      });
      final Timer heartbeat = Timer.periodic(heartbeatInterval, (Timer _) {
        try {
          unawaited(ping().catchError((Object _) => _closeSocket()));
        } on Object {
          // Not connected any more; the session loop is already reconnecting.
          unawaited(_closeSocket());
        }
      });
      try {
        while (_running) {
          final Map<String, dynamic> frame = await _next(iterator);
          _dispatch(frame);
        }
      } finally {
        refresher.cancel();
        heartbeat.cancel();
      }
    } finally {
      await iterator.cancel();
    }
  }

  Future<void> refreshAuth() async {
    final SignalSocket? socket = _socket;
    if (socket == null) return;
    final Map<String, dynamic> ticket = await api.signalTicket(identity.nodeId);
    await _sendAuth(socket, ticket, 'auth.refresh');
  }

  Future<void> _sendAuth(
    SignalSocket socket,
    Map<String, dynamic> ticket,
    String type,
  ) async {
    final Object? value = ticket['ticket'];
    final Object? challenge = ticket['challenge'];
    if (value is! String || challenge is! String) {
      throw const HiveApiException('The hive server returned an invalid ticket.');
    }
    final String sig = await identity.sign(
      await signalAuthMessage(challenge, value, identity.nodeId),
    );
    socket.send(
      jsonEncode(<String, dynamic>{
        'v': protocolVersion,
        'type': type,
        'data': <String, dynamic>{
          'ticket': value,
          'sig': sig,
          if (type == 'auth') 'node_id': identity.nodeId,
        },
      }),
    );
  }

  Future<Map<String, dynamic>> _next(StreamIterator<String> iterator) async {
    if (!await iterator.moveNext()) {
      throw StateError('Signalling socket closed.');
    }
    final String raw = iterator.current;
    if (utf8.encode(raw).length > maxSignalFrameBytes) {
      throw StateError('Oversized signalling frame.');
    }
    final Object? frame = jsonDecode(raw);
    if (frame is! Map || frame['type'] is! String) {
      throw StateError('Invalid signalling frame.');
    }
    return frame.cast<String, dynamic>();
  }

  void _dispatch(Map<String, dynamic> frame) {
    final Object? data = frame['data'];
    if (!_frames.isClosed) {
      _frames.add(
        SignalFrame(
          frame['type'] as String,
          data is Map ? data.cast<String, dynamic>() : const <String, dynamic>{},
        ),
      );
    }
  }

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    if (!_connection.isClosed) _connection.add(value);
    if (value) {
      _connectedSignal?.complete();
      _connectedSignal = null;
    }
  }

  Future<void> _closeSocket() async {
    final SignalSocket? socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close();
      } on Object {
        // Already closed.
      }
    }
  }
}
