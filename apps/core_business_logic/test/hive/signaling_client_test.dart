import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'fakes.dart';
import 'peer_connector_test.dart' show until;

final class FakeSignalSocket implements SignalSocket {
  final StreamController<String> controller = StreamController<String>();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  Stream<String> get messages => controller.stream;
  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, dynamic>);
  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) await controller.close();
  }

  void server(String type, [Map<String, dynamic> data = const <String, dynamic>{}]) =>
      controller.add(jsonEncode(<String, dynamic>{'v': 1, 'type': type, 'data': data}));
}

void main() {
  test('signalUrl maps http(s) to ws(s) and appends /signal', () {
    expect(signalUrl(Uri.parse('https://api.example.com')).toString(), 'wss://api.example.com/signal');
    expect(signalUrl(Uri.parse('http://localhost:8000/base/')).toString(), 'ws://localhost:8000/base/signal');
  });

  test('backoff stays within bounds and grows', () {
    for (int attempt = 0; attempt < 30; attempt++) {
      for (final double r in <double>[0, 0.5, 1]) {
        final Duration d = backoffDelay(attempt, random: () => r);
        expect(d, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
        expect(d, lessThanOrEqualTo(const Duration(seconds: 60)));
      }
    }
    expect(backoffDelay(3, random: () => 1), const Duration(seconds: 8));
    expect(backoffDelay(0, random: () => 0), const Duration(milliseconds: 500));
  });

  group('SignalingClient', () {
    late NodeIdentity me;
    late List<http.Request> requests;
    late int ticketCount;
    late HiveApi api;

    setUp(() async {
      me = await seededIdentity(40);
      requests = <http.Request>[];
      ticketCount = 0;
      api = HiveApi(
        baseUri: Uri.parse('https://api.test/'),
        accessToken: () => 'access',
        client: MockClient((http.Request request) async {
          requests.add(request);
          ticketCount++;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ticket': 'ticket-$ticketCount',
              'challenge': 'challenge-$ticketCount',
              'expires_in': 30,
            }),
            200,
          );
        }),
      );
    });

    test('fetches a ticket, authenticates with a signed challenge, sets presence', () async {
      final FakeSignalSocket socket = FakeSignalSocket();
      final List<Uri> urls = <Uri>[];
      final SignalingClient client = SignalingClient(
        api: api,
        identity: me,
        connect: (Uri url) async {
          urls.add(url);
          return socket;
        },
        sleep: (Duration _) async {},
      );
      client.start();
      await until(() => socket.sent.isNotEmpty);

      expect(requests.single.url.path, '/nodes/${me.nodeId}/signal-ticket');
      expect(requests.single.headers['Authorization'], 'Bearer access');
      expect(urls.single.toString(), 'wss://api.test/signal');
      final Map<String, dynamic> auth = socket.sent.single;
      expect(auth['type'], 'auth');
      final Map<String, dynamic> data = auth['data'] as Map<String, dynamic>;
      expect(data['ticket'], 'ticket-1');
      expect(data['node_id'], me.nodeId);
      expect(
        await verifySignature(
          publicKey: me.publicKey,
          signature: data['sig'] as String,
          message: await signalAuthMessage('challenge-1', 'ticket-1', me.nodeId),
        ),
        isTrue,
      );

      final Future<SignalFrame> presence = client.frames.firstWhere(
        (SignalFrame f) => f.type == 'presence.snapshot',
      );
      socket.server('auth.ok', <String, dynamic>{'node_id': me.nodeId, 'hive_id': 'hive-1'});
      await client.waitConnected(const Duration(seconds: 2));
      expect(client.hiveId, 'hive-1');
      await until(() => socket.sent.length >= 2);
      expect(socket.sent[1]['type'], 'presence.set');

      socket.server('presence.snapshot', <String, dynamic>{
        'nodes': <Map<String, dynamic>>[
          <String, dynamic>{'node_id': 'n_x', 'online': true},
        ],
      });
      expect((await presence).data['nodes'], isNotEmpty);

      await client.sendSignal(sid: 's', to: 'n_x', kind: 'offer', body: <String, dynamic>{'sdp': 'v=0'}, sig: 'sig');
      await client.sendRelay(sid: 's', to: 'n_x', payload: 'cipher');
      await client.setPresence(clients: <String>['ui'], capabilities: <String, dynamic>{'a': 1});
      await client.ping();
      final List<String> types = socket.sent.map((Map<String, dynamic> f) => f['type'] as String).toList();
      expect(types.sublist(2), <String>['signal', 'relay', 'presence.set', 'ping']);
      final Map<String, dynamic> signal = (socket.sent[2]['data'] as Map).cast<String, dynamic>();
      expect(signal['to'], 'n_x');
      expect(signal['sig'], 'sig');
      expect((socket.sent[3]['data'] as Map)['payload'], 'cipher');
      await client.dispose();
    });

    test('refreshes the ticket over the open socket with auth.refresh', () async {
      final FakeSignalSocket socket = FakeSignalSocket();
      final SignalingClient client = SignalingClient(
        api: api,
        identity: me,
        connect: (Uri _) async => socket,
        sleep: (Duration _) async {},
      );
      client.start();
      await until(() => socket.sent.isNotEmpty);
      socket.server('auth.ok', <String, dynamic>{'hive_id': 'h'});
      await client.waitConnected(const Duration(seconds: 2));
      await client.refreshAuth();
      final Map<String, dynamic> refresh = socket.sent.last;
      expect(refresh['type'], 'auth.refresh');
      final Map<String, dynamic> data = (refresh['data'] as Map).cast<String, dynamic>();
      expect(data.containsKey('node_id'), isFalse);
      expect(
        await verifySignature(
          publicKey: me.publicKey,
          signature: data['sig'] as String,
          message: await signalAuthMessage('challenge-2', 'ticket-2', me.nodeId),
        ),
        isTrue,
      );
      await client.dispose();
    });

    test('reconnects with a fresh ticket after a drop and backs off', () async {
      final List<FakeSignalSocket> sockets = <FakeSignalSocket>[];
      final List<Duration> sleeps = <Duration>[];
      final SignalingClient client = SignalingClient(
        api: api,
        identity: me,
        connect: (Uri _) async {
          final FakeSignalSocket s = FakeSignalSocket();
          sockets.add(s);
          return s;
        },
        sleep: (Duration d) async => sleeps.add(d),
        random: () => 1,
      );
      client.start();
      await until(() => sockets.length == 1 && sockets[0].sent.isNotEmpty);
      // Server rejects auth by closing (4401 in production).
      await sockets[0].controller.close();
      await until(() => sockets.length == 2 && sockets[1].sent.isNotEmpty);
      expect(sleeps, isNotEmpty);
      expect(sleeps.first, const Duration(seconds: 1));
      expect(((sockets[1].sent.first['data'] as Map)['ticket']), 'ticket-2');
      expect(client.connected, isFalse);
      await client.dispose();
    });

    test('an auth reply other than auth.ok is treated as a failure', () async {
      final List<FakeSignalSocket> sockets = <FakeSignalSocket>[];
      final SignalingClient client = SignalingClient(
        api: api,
        identity: me,
        connect: (Uri _) async {
          final FakeSignalSocket s = FakeSignalSocket();
          sockets.add(s);
          return s;
        },
        sleep: (Duration _) async {},
        random: () => 0,
      );
      client.start();
      await until(() => sockets.isNotEmpty && sockets[0].sent.isNotEmpty);
      sockets[0].server('error', <String, dynamic>{'code': 'auth_failed'});
      await until(() => sockets.length >= 2);
      expect(client.connected, isFalse);
      await client.dispose();
    });

    test('sending while disconnected throws', () async {
      final SignalingClient client = SignalingClient(api: api, identity: me);
      expect(
        () => client.sendSignal(sid: 's', to: 'n', kind: 'bye', body: <String, dynamic>{}),
        throwsStateError,
      );
    });
  });
}
