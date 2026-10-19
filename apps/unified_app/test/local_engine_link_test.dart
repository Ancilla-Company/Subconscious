import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';

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

final class _NoTransport implements PeerTransportFactory {
  const _NoTransport();
  @override
  Future<PeerTransport> create({required List<Map<String, dynamic>> iceServers}) =>
      throw UnimplementedError();
}

Future<SignalSocket> _neverConnects(Uri _) => Completer<SignalSocket>().future;

/// Everything one test needs: a runtime that expects a local engine, the
/// requests the server saw and a fake local engine.
final class _Rig {
  _Rig._(this.runtime, this.server, this.engine);
  final HiveRuntime runtime;
  final List<http.Request> server;
  final List<http.Request> engine;

  int get registrations => server
      .where((http.Request r) => r.method == 'POST' && r.url.path == '/nodes')
      .length;
  List<http.Request> get patches =>
      server.where((http.Request r) => r.method == 'PATCH').toList();

  static Future<_Rig> create({
    int patchStatus = 200,
    int probesBeforeFound = 1 << 30,
  }) async {
    final List<http.Request> server = <http.Request>[];
    final List<http.Request> engine = <http.Request>[];
    final MemoryIdentitySeedStore seeds = MemoryIdentitySeedStore();
    await loadOrCreateIdentity(seeds);
    final MockClient serverMock = MockClient((http.Request r) async {
      server.add(r);
      if (r.url.path == '/auth/email/login') {
        return http.Response(jsonEncode(_loginBody), 200);
      }
      if (r.method == 'PATCH') return http.Response('{}', patchStatus);
      if (r.method == 'POST' && r.url.path == '/nodes') {
        return http.Response('{}', 200);
      }
      if (r.method == 'GET' && r.url.path == '/nodes') {
        return http.Response(jsonEncode(<String, dynamic>{'nodes': <Object?>[]}), 200);
      }
      return http.Response('{}', 404);
    });
    final ServerAccountClient account = ServerAccountClient(
      baseUri: Uri.parse('https://api.test'),
      tokenStore: MemoryRefreshTokenStore(),
      client: serverMock,
    );
    final HiveRuntime runtime = HiveRuntime(
      account: account,
      localProbeDelays: const <Duration>[
        Duration(milliseconds: 1),
        Duration(milliseconds: 1),
      ],
      probeSleep: (Duration _) => Future<void>.delayed(const Duration(milliseconds: 1)),
      hive: HiveClient(
        account: account,
        seedStore: seeds,
        pinStoreFactory: (String _) async => MemoryPinStore(),
        transportFactory: const _NoTransport(),
        deviceName: 'Windows PC',
        platform: 'windows',
        appVersion: '1',
        signalConnect: _neverConnects,
        httpClient: serverMock,
        apiRetryDelays: const <Duration>[],
      ),
    );
    runtime.expectsLocalEngine = true;
    int probes = 0;
    runtime.probeLocalEngine = () async => ++probes > probesBeforeFound;
    runtime.localEngineClient = () async => RestEngineClient(
      baseUri: Uri.parse('http://127.0.0.1:1/api/v1/'),
      token: 't',
      client: MockClient((http.Request r) async {
        engine.add(r);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'state': 'running',
            'nodes': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'n_engine',
                'kind': 'engine',
                'name': 'Windows PC',
                'platform': 'windows',
                'status': 'active',
                'trusted': true,
                'local': true,
                'online': true,
              },
            ],
          }),
          200,
        );
      }),
    );
    runtime.onEngineAvailable = () async {};
    return _Rig._(runtime, server, engine);
  }
}

Future<void> until(bool Function() condition) async {
  for (int i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('while waiting for the engine the linking state shows and no device is registered', () async {
    final _Rig rig = await _Rig.create(); // the probe never succeeds
    addTearDown(rig.runtime.dispose);
    await rig.runtime.signIn(email: 'a@b.c', password: 'password1');
    expect(rig.runtime.linkingLocalEngine, isTrue);
    expect(rig.runtime.status, HiveStatus.busy);
    expect(rig.registrations, 0);
    await until(() => rig.runtime.localEngineMissing);
  });

  test('expiry sets localEngineMissing and still registers nothing', () async {
    final _Rig rig = await _Rig.create();
    addTearDown(rig.runtime.dispose);
    await rig.runtime.signIn(email: 'a@b.c', password: 'password1');
    await until(() => rig.runtime.localEngineMissing);
    expect(rig.runtime.localEngineMissing, isTrue);
    expect(rig.runtime.linkingLocalEngine, isFalse);
    expect(rig.runtime.status, HiveStatus.ready);
    expect(rig.registrations, 0);
  });

  test('a late engine goes the engine path with zero device registrations', () async {
    final _Rig rig = await _Rig.create(probesBeforeFound: 1);
    addTearDown(rig.runtime.dispose);
    int reconnects = 0;
    rig.runtime.onEngineAvailable = () async => reconnects++;
    await rig.runtime.signIn(email: 'a@b.c', password: 'password1');
    await until(() => rig.runtime.hasLocalFullNode);
    expect(rig.runtime.hasLocalFullNode, isTrue);
    expect(rig.runtime.linkingLocalEngine, isFalse);
    expect(reconnects, greaterThan(0));
    await until(() => rig.patches.isNotEmpty);
    expect(rig.registrations, 0);
  });

  test('useThisPcAsRemoteClient registers a thin device', () async {
    final _Rig rig = await _Rig.create();
    addTearDown(rig.runtime.dispose);
    await rig.runtime.signIn(email: 'a@b.c', password: 'password1');
    await until(() => rig.runtime.localEngineMissing);
    await rig.runtime.useThisPcAsRemoteClient();
    expect(rig.registrations, 1);
    expect(rig.runtime.allowThinFallback, isTrue);
    expect(rig.runtime.localEngineMissing, isFalse);
  });

  test('markLocalEngineFound twice links once, with one PATCH', () async {
    final _Rig rig = await _Rig.create();
    addTearDown(rig.runtime.dispose);
    await rig.runtime.signIn(email: 'a@b.c', password: 'password1');
    rig.runtime.markLocalEngineFound();
    rig.runtime.markLocalEngineFound();
    await until(() => rig.patches.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rig.patches, hasLength(1));
    final http.Request patch = rig.patches.single;
    expect(jsonDecode(patch.body), <String, dynamic>{'parent_node_id': 'n_engine'});
    expect(rig.registrations, 0);
  });

  test('a 404 from an old server on the PATCH is swallowed', () async {
    final _Rig rig = await _Rig.create(patchStatus: 404);
    addTearDown(rig.runtime.dispose);
    await rig.runtime.signIn(email: 'a@b.c', password: 'password1');
    rig.runtime.markLocalEngineFound();
    await until(() => rig.patches.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rig.patches, hasLength(1));
    expect(rig.runtime.error, isNull);
    expect(rig.runtime.status, HiveStatus.ready);
  });

  test('sign-in sends device_name and a 32 hex client_id to the engine login', () async {
    final _Rig rig = await _Rig.create();
    addTearDown(rig.runtime.dispose);
    final List<http.Request> engineLogins = <http.Request>[];
    rig.runtime.localEngineClient = () async => RestEngineClient(
      baseUri: Uri.parse('http://127.0.0.1:1/api/v1/'),
      token: 't',
      client: MockClient((http.Request r) async {
        engineLogins.add(r);
        return http.Response(
          jsonEncode(<String, dynamic>{'signedIn': true, 'email': 'a@b.c'}),
          200,
        );
      }),
    );
    final AccountController controller = AccountController(
      session: rig.runtime,
      clientProvider: () => rig.runtime.localEngineClient!.call(),
    );
    addTearDown(controller.dispose);
    expect(await controller.signIn(email: 'a@b.c', password: 'password1'), isTrue);
    final http.Request login = engineLogins.firstWhere(
      (http.Request r) => r.url.path.endsWith('/account/login'),
    );
    final Map<String, dynamic> body = jsonDecode(login.body) as Map<String, dynamic>;
    expect(body['device_name'], rig.runtime.deviceName);
    expect(body['client_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
    // The id is stable across calls.
    expect(await rig.runtime.clientId(), body['client_id']);
  });
}
