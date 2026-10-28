import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/hive/engine_card_view.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/hive/reconcile_backoff.dart';

const Map<String, dynamic> _loginBody = <String, dynamic>{
  'access_token': 'a',
  'token_type': 'bearer',
  'expires_in': 900,
  'refresh_token': 'r',
  'user': <String, dynamic>{
    'id': 'u-1',
    'email': 'a@b.c',
    'display_name': 'A',
    'avatar_url': null,
    'connected_providers': <String>[],
  },
};

NodeView _engine(String id, {bool online = true}) => NodeView(
  node: DirectoryNode(
    id: id,
    kind: 'engine',
    name: 'Engine $id',
    platform: 'windows',
    appVersion: '',
    publicKey: Uint8List(32),
    status: 'active',
    online: online,
  ),
  trusted: true,
  online: online,
  isLocal: false,
);

Future<HiveRuntime> _runtime({
  Duration grace = const Duration(milliseconds: 300),
}) async {
  final HiveRuntime runtime = HiveRuntime(
    engineOfflineGrace: grace,
    account: ServerAccountClient(
      baseUri: Uri.parse('https://api.test'),
      tokenStore: MemoryRefreshTokenStore(),
      client: MockClient(
        (http.Request r) async => http.Response(jsonEncode(_loginBody), 200),
      ),
    ),
  );
  await runtime.account.loginWithEmail(email: 'a@b.c', password: 'password1');
  return runtime;
}

/// A signalling socket that never connects, so no timers or sockets leak.
Future<SignalSocket> _neverConnects(Uri _) => Completer<SignalSocket>().future;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('ReconcileBackoff doubles from 5 s to 120 s and resets', () {
    final ReconcileBackoff backoff = ReconcileBackoff();
    expect(
      <int>[for (int i = 0; i < 7; i++) backoff.next().inSeconds],
      <int>[5, 10, 20, 40, 80, 120, 120],
    );
    backoff.reset();
    expect(backoff.next().inSeconds, 5);
  });

  test(
    'the home engine survives a short offline blip and drops after the grace',
    () async {
      final HiveRuntime runtime = await _runtime();
      addTearDown(runtime.dispose);
      runtime.onEngineAvailable = () async {};
      runtime.homeEngineId = 'a';
      runtime.engineState = EngineLinkState.connected;
      runtime.nodes = <NodeView>[_engine('a', online: false)];
      await runtime.maybeAutoConnect();
      expect(runtime.homeEngineId, 'a', reason: 'inside the grace window');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await runtime.maybeAutoConnect();
      expect(runtime.homeEngineId, 'a');
      expect(runtime.engineState, EngineLinkState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        runtime.homeEngineId,
        isNull,
        reason: 'still offline after the grace',
      );
      expect(runtime.engineState, EngineLinkState.disconnected);
    },
  );

  test(
    'an engine that comes back inside the grace window keeps the link',
    () async {
      final HiveRuntime runtime = await _runtime();
      addTearDown(runtime.dispose);
      runtime.onEngineAvailable = () async {};
      runtime.homeEngineId = 'a';
      runtime.engineState = EngineLinkState.connected;
      runtime.nodes = <NodeView>[_engine('a', online: false)];
      await runtime.maybeAutoConnect();
      runtime.nodes = <NodeView>[_engine('a')];
      await runtime.maybeAutoConnect();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(runtime.homeEngineId, 'a');
      expect(runtime.engineState, EngineLinkState.connected);
    },
  );

  test(
    'inEngineHysteresis covers the window after the last engine left',
    () async {
      final HiveRuntime runtime = await _runtime(
        grace: const Duration(milliseconds: 200),
      );
      addTearDown(runtime.dispose);
      runtime.onEngineAvailable = () async {};
      runtime.nodes = <NodeView>[_engine('a')];
      await runtime.maybeAutoConnect();
      runtime.nodes = <NodeView>[_engine('a', online: false)];
      await runtime.maybeAutoConnect();
      expect(runtime.inEngineHysteresis, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(runtime.inEngineHysteresis, isFalse);
    },
  );

  test('disconnect never leaves connected with auto-connect off', () async {
    final HiveRuntime runtime = await _runtime();
    addTearDown(runtime.dispose);
    runtime.onEngineAvailable = () async {};
    final List<String> bad = <String>[];
    runtime.addListener(() {
      if (runtime.engineState == EngineLinkState.connected &&
          !runtime.autoConnect) {
        bad.add('connected with auto-connect off');
      }
    });
    runtime.homeEngineId = 'a';
    runtime.engineState = EngineLinkState.connected;
    await runtime.disconnectEngine();
    expect(runtime.engineState, EngineLinkState.disconnected);
    expect(runtime.autoConnect, isFalse);
    await runtime.reconnectEngine();
    runtime.homeEngineId = 'a';
    runtime.engineState = EngineLinkState.connected;
    await runtime.disconnectEngine();
    expect(runtime.engineState, EngineLinkState.disconnected);
    expect(runtime.autoConnect, isFalse);
    expect(bad, isEmpty);
  });

  test('the reconcile loop runs only while push cannot be trusted', () async {
    final HiveRuntime runtime = await _runtime();
    addTearDown(runtime.dispose);
    runtime.thinActive = true;
    runtime.signalConnected = false;
    expect(runtime.shouldReconcile, isTrue, reason: 'socket down');
    runtime.signalConnected = true;
    expect(runtime.shouldReconcile, isFalse, reason: 'connected and healthy');
    runtime.serverUnavailable = true;
    expect(runtime.shouldReconcile, isTrue, reason: 'connected but 502');
    runtime.serverUnavailable = false;
    runtime.hasLocalFullNode = true;
    runtime.signalConnected = false;
    expect(
      runtime.shouldReconcile,
      isFalse,
      reason: 'local engine owns the list',
    );
  });

  test(
    '502 keeps the list and sets serverUnavailable; success clears both',
    () async {
      final MemoryIdentitySeedStore seeds = MemoryIdentitySeedStore();
      final NodeIdentity me = await loadOrCreateIdentity(seeds);
      int listCalls = 0;
      int failures = 2;
      final MockClient mock = MockClient((http.Request r) async {
        if (r.url.path == '/auth/email/login') {
          return http.Response(jsonEncode(_loginBody), 200);
        }
        if (r.method == 'POST' && r.url.path == '/nodes') {
          return http.Response('{}', 200);
        }
        if (r.method == 'GET' && r.url.path == '/nodes') {
          listCalls++;
          if (listCalls > 1 && failures > 0) {
            failures--;
            return http.Response('bad gateway', 502);
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'hive_id': 'h',
              'nodes': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': me.nodeId,
                  'public_key': me.publicKeyB64u,
                  'kind': 'thin',
                  'name': 'Me',
                  'platform': 'android',
                  'status': 'active',
                  'online': true,
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final ServerAccountClient account = ServerAccountClient(
        baseUri: Uri.parse('https://api.test'),
        tokenStore: MemoryRefreshTokenStore(),
        client: mock,
      );
      final HiveRuntime runtime = HiveRuntime(
        account: account,
        hive: HiveClient(
          account: account,
          seedStore: seeds,
          pinStoreFactory: (String _) async => MemoryPinStore(),
          transportFactory: const _NoTransport(),
          deviceName: 'Me',
          platform: 'android',
          appVersion: '1',
          signalConnect: _neverConnects,
          httpClient: mock,
          apiRetryDelays: const <Duration>[],
        ),
      );
      addTearDown(runtime.dispose);
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      expect(runtime.nodes, hasLength(1));
      expect(runtime.serverUnavailable, isFalse);

      await runtime.refresh(); // 502
      expect(runtime.serverUnavailable, isTrue);
      expect(runtime.error, isNull, reason: '502 is not an error to act on');
      expect(runtime.nodes, hasLength(1), reason: 'the last list is kept');
      await runtime.refresh(); // 502
      expect(runtime.serverUnavailable, isTrue);
      await runtime.refresh(); // 200
      expect(runtime.serverUnavailable, isFalse);
      expect(runtime.error, isNull);
      expect(runtime.nodes, hasLength(1));
    },
  );

  test('the card view names the reconnect window and the pick row', () async {
    final EngineCardView view = buildEngineCardView(
      engineState: EngineLinkState.disconnected,
      autoConnect: true,
      choice: EngineChoiceKind.none,
      hasCandidates: false,
      inHysteresis: true,
    );
    expect(view.title, 'Reconnecting to engine...');
    expect(view.isConnecting, isTrue);
  });
}

final class _NoTransport implements PeerTransportFactory {
  const _NoTransport();
  @override
  Future<PeerTransport> create({
    required List<Map<String, dynamic>> iceServers,
  }) => throw UnimplementedError();
}
