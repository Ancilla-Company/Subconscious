import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _HangingSink implements WebSocketSink {
  @override
  Future<void> get done => Completer<void>().future;
  @override
  void add(dynamic data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) => Completer<void>().future;
  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      Completer<void>().future; // never completes, like a dead server
}

final class _HangingChannel implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  @override
  Future<void> get ready => Future<void>.value();
  @override
  Stream<dynamic> get stream => _incoming.stream;
  @override
  WebSocketSink get sink => _HangingSink();
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  String? get protocol => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('dispose does not wait on a close handshake that never finishes', () async {
    final _HangingChannel channel = _HangingChannel();
    final WebSocketEngineClient client = WebSocketEngineClient(
      endpoint: Uri.parse('ws://127.0.0.1:1/api/v1/events'),
      channelFactory: (Uri _) => channel,
    );
    // Connect never completes the hello, so drive state directly.
    unawaited(client.connect().catchError((Object _) {}));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final Stopwatch watch = Stopwatch()..start();
    await client.dispose();
    expect(watch.elapsedMilliseconds, lessThan(1000));
  });
}
