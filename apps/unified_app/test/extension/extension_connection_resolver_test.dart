import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/extension/extension_connection_resolver.dart';
import 'package:unified_app/features/extension/extension_host.dart';

import 'fake_extension_host.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

EngineRepository _hiveRepository() => EngineRepository(
  rest: RestEngineClient(
    baseUri: Uri.parse('http://peer.invalid/api/v1/'),
    token: '',
  ),
  socket: PeerEngineSocket(linkProvider: () async => throw StateError('x')),
);

void main() {
  late FakeExtensionHost host;
  late List<String> order;
  late EngineRepository hiveRepo;

  Future<EngineRepository?> hive() async {
    order.add('hive');
    return hiveRepo;
  }

  /// An engine accepting only [validToken].
  http.Client engine({String validToken = 'scp_good', bool down = false}) =>
      MockClient((http.Request request) async {
        order.add('${request.method} ${request.url.path}');
        if (down) throw http.ClientException('refused');
        if (request.url.path.endsWith('/health')) {
          return _json(<String, dynamic>{'status': 'ok'});
        }
        if (request.headers['Authorization'] != 'Bearer $validToken') {
          return _json(<String, dynamic>{'detail': 'bad'}, 401);
        }
        return _json(<dynamic>[]);
      });

  setUp(() {
    host = FakeExtensionHost(
      connection: const ExtensionConnection(
        engineUrl: 'http://127.0.0.1:51516',
        engineToken: 'scp_good',
      ),
    );
    order = <String>[];
    hiveRepo = _hiveRepository();
  });

  test('a valid paired token wins over the hive path', () async {
    final EngineRepository? repository = await resolveExtensionRepository(
      host: host,
      hive: hive,
      httpClient: engine(),
    );
    expect(repository, isNotNull);
    expect(repository, isNot(same(hiveRepo)));
    expect(repository!.rest.token, 'scp_good');
    expect(order, <String>['GET /api/v1/health', 'GET /api/v1/workspaces']);
    expect(repository.socket, isA<WebSocketEngineClient>());
    final WebSocketEngineClient socket =
        repository.socket as WebSocketEngineClient;
    expect(socket.endpoint.queryParameters['token'], 'scp_good');
    expect(socket.identity?.type, ClientType.browserExtension);
    expect(socket.identity?.name, 'Chromium extension');
    expect(socket.identity?.version, '1.2.3');
  });

  test(
    'an engine reached over loopback is reported as on this device',
    () async {
      int local = 0;
      await resolveExtensionRepository(
        host: host,
        hive: hive,
        httpClient: engine(),
        onLocalEngine: () => local++,
      );
      expect(local, 1);
    },
  );

  test('a paired engine on another machine is not "this device"', () async {
    host.connection = const ExtensionConnection(
      engineUrl: 'http://192.168.1.20:51516',
      engineToken: 'scp_good',
    );
    int local = 0;
    final EngineRepository? repository = await resolveExtensionRepository(
      host: host,
      hive: hive,
      httpClient: engine(),
      onLocalEngine: () => local++,
    );
    expect(repository, isNotNull);
    expect(local, 0);
  });

  test('the hive path never counts as a local engine', () async {
    host.connection = null;
    int local = 0;
    await resolveExtensionRepository(
      host: host,
      hive: hive,
      httpClient: engine(),
      onLocalEngine: () => local++,
    );
    expect(local, 0);
  });

  test('loopback detection', () {
    for (final String url in <String>[
      'http://127.0.0.1:51516',
      'http://localhost:51515',
      'http://127.1.2.3',
      'http://[::1]:51516',
    ]) {
      expect(isLoopbackEngineUrl(url), isTrue, reason: url);
    }
    for (final String? url in <String?>[
      'http://192.168.1.20:51516',
      'https://engine.example.com',
      'not a url',
      '',
      null,
    ]) {
      expect(isLoopbackEngineUrl(url), isFalse, reason: '$url');
    }
  });

  test('a stored loopback pairing is detected and probed', () async {
    expect(await hasLoopbackPairing(host), isTrue);
    expect(
      await pairedLocalEngineReachable(host, httpClient: engine()),
      isTrue,
    );
    expect(
      await pairedLocalEngineReachable(host, httpClient: engine(down: true)),
      isFalse,
    );
    host.connection = null;
    expect(await hasLoopbackPairing(host), isFalse);
    expect(
      await pairedLocalEngineReachable(host, httpClient: engine()),
      isFalse,
    );
  });

  test('no paired token falls back to the hive path', () async {
    host.connection = null;
    final EngineRepository? repository = await resolveExtensionRepository(
      host: host,
      hive: hive,
      httpClient: engine(),
    );
    expect(repository, same(hiveRepo));
    expect(order, <String>['hive']);
  });

  test('an engine that is not running falls back to the hive path', () async {
    final EngineRepository? repository = await resolveExtensionRepository(
      host: host,
      hive: hive,
      httpClient: engine(down: true),
    );
    expect(repository, same(hiveRepo));
    expect(
      host.cleared,
      0,
      reason: 'the token is kept while the engine is down',
    );
  });

  test('a 401 clears the token and re-pairs when a session exists', () async {
    host.connection = const ExtensionConnection(
      engineUrl: 'http://127.0.0.1:51516',
      engineToken: 'scp_stale',
    );
    int rePairs = 0;
    final EngineRepository? repository = await resolveExtensionRepository(
      host: host,
      hive: hive,
      httpClient: engine(),
      rePair: () async {
        rePairs++;
        return const ExtensionConnection(
          engineUrl: 'http://127.0.0.1:51516',
          engineToken: 'scp_good',
        );
      },
    );
    expect(host.cleared, 1);
    expect(rePairs, 1);
    expect(repository!.rest.token, 'scp_good');
    expect(order, isNot(contains('hive')));
  });

  test(
    'a 401 without a session ends on the hive path (then the Account page)',
    () async {
      host.connection = const ExtensionConnection(
        engineUrl: 'http://127.0.0.1:51516',
        engineToken: 'scp_stale',
      );
      final EngineRepository? repository = await resolveExtensionRepository(
        host: host,
        hive: () async => null,
        httpClient: engine(),
        rePair: () async => null,
      );
      expect(host.cleared, 1);
      expect(repository, isNull);
    },
  );

  test('a throwing hive path gives null instead of an exception', () async {
    host.connection = null;
    expect(
      await resolveExtensionRepository(
        host: host,
        hive: () async => throw StateError('boom'),
      ),
      isNull,
    );
  });
}
