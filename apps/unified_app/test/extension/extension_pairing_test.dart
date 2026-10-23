import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/extension/extension_host.dart';
import 'package:unified_app/features/extension/extension_pairing.dart';
import 'package:unified_app/features/extension/extension_pairing_controller.dart';

import 'fake_extension_host.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  late FakeExtensionHost host;
  late List<http.Request> requests;
  late List<Map<String, String>> assertionCalls;

  /// An engine on [ports] answering health with [nodeId]; `/pair` answers
  /// [pairStatus].
  ExtensionPairing make({
    Set<int> ports = const <int>{51516},
    String? nodeId = 'n_engine',
    int pairStatus = 200,
    bool preferDev = false,
    Future<String> Function()? assertion,
  }) {
    final http.Client client = MockClient((http.Request request) async {
      requests.add(request);
      if (!ports.contains(request.url.port)) {
        throw http.ClientException('connection refused');
      }
      if (request.url.path == '/api/v1/health') {
        return _json(<String, dynamic>{'status': 'ok', 'node_id': nodeId});
      }
      if (request.url.path == '/api/v1/pair') {
        if (pairStatus != 200) {
          return _json(<String, dynamic>{'detail': 'x'}, pairStatus);
        }
        return _json(<String, dynamic>{
          'token': 'scp_token',
          'client_id': 'client-1',
          'expires_at': '2030-01-01T00:00:00Z',
        });
      }
      return http.Response('not found', 404);
    });
    return ExtensionPairing(
      client: client,
      host: host,
      preferDev: preferDev,
      requestAssertion:
          ({
            required String nodeId,
            required String clientNonce,
            required String origin,
          }) async {
            assertionCalls.add(<String, String>{
              'node_id': nodeId,
              'client_nonce': clientNonce,
              'origin': origin,
            });
            return assertion != null ? assertion() : 'assertion-1';
          },
    );
  }

  setUp(() {
    host = FakeExtensionHost();
    requests = <http.Request>[];
    assertionCalls = <Map<String, String>>[];
  });

  test('probes production then development and reads node_id', () async {
    final ExtensionPairing pairing = make(ports: <int>{51515});
    final FoundEngine? engine = await pairing.findEngine();
    expect(engine?.url.port, 51515);
    expect(engine?.nodeId, 'n_engine');
    expect(requests.map((http.Request r) => r.url.port).toList(), <int>[
      51516,
      51515,
    ]);
  });

  test('a development build tries 51515 first', () async {
    final ExtensionPairing pairing = make(
      ports: <int>{51515, 51516},
      preferDev: true,
    );
    expect((await pairing.findEngine())?.url.port, 51515);
  });

  test('no engine answering gives null', () async {
    expect(await make(ports: <int>{}).findEngine(), isNull);
  });

  test('an engine without a node id is found but cannot pair', () async {
    final ExtensionPairing pairing = make(nodeId: null);
    final FoundEngine engine = (await pairing.findEngine())!;
    expect(engine.nodeId, isNull);
    await expectLater(
      pairing.pair(engine),
      throwsA(
        isA<PairingException>().having(
          (PairingException e) => e.message,
          'message',
          contains('same account'),
        ),
      ),
    );
  });

  test(
    'pairs: nonce is 43 base64url chars, token is stored in the host',
    () async {
      final ExtensionPairing pairing = make();
      final FoundEngine engine = (await pairing.findEngine())!;
      final ExtensionConnection connection = await pairing.pair(
        engine,
        serverUrl: 'https://api.subconscious.chat',
        environment: 'production',
      );
      expect(assertionCalls.single['node_id'], 'n_engine');
      expect(assertionCalls.single['origin'], host.extensionOrigin);
      final String nonce = assertionCalls.single['client_nonce']!;
      expect(nonce, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      final http.Request pair = requests.last;
      expect(pair.method, 'POST');
      expect(pair.url.toString(), 'http://127.0.0.1:51516/api/v1/pair');
      expect(jsonDecode(pair.body), <String, dynamic>{
        'assertion': 'assertion-1',
        'client_nonce': nonce,
      });
      expect(connection.engineToken, 'scp_token');
      expect(host.connection?.engineUrl, 'http://127.0.0.1:51516');
      expect(host.connection?.engineToken, 'scp_token');
      expect(host.connection?.clientId, 'client-1');
      expect(host.connection?.serverUrl, 'https://api.subconscious.chat');
      expect(host.connection?.environment, 'production');
    },
  );

  test('two nonces differ', () {
    final ExtensionPairing pairing = make();
    expect(pairing.newNonce(), isNot(pairing.newNonce()));
  });

  group('engine errors become plain-language messages', () {
    for (final (int, String) item in <(int, String)>[
      (
        401,
        'Sign this engine in to the same account in the desktop app, then retry',
      ),
      (403, 'refused this extension'),
      (404, 'expired'),
      (429, 'Too many pairing attempts'),
      (503, 'could not reach the Subconscious server'),
    ]) {
      test('${item.$1}', () async {
        final ExtensionPairing pairing = make(pairStatus: item.$1);
        final FoundEngine engine = (await pairing.findEngine())!;
        await expectLater(
          pairing.pair(engine),
          throwsA(
            isA<PairingException>()
                .having(
                  (PairingException e) => e.message,
                  'message',
                  contains(item.$2),
                )
                .having(
                  (PairingException e) => e.statusCode,
                  'status',
                  item.$1,
                ),
          ),
        );
        expect(host.connection, isNull);
      });
    }
  });

  group('server assertion errors', () {
    for (final (int, String) item in <(int, String)>[
      (404, 'not registered to your account'),
      (403, 'removed from your account'),
      (429, 'Too many pairing attempts'),
      (401, 'session expired'),
    ]) {
      test('${item.$1}', () async {
        final ExtensionPairing pairing = make(
          assertion: () async => throw HiveApiException('x', item.$1),
        );
        final FoundEngine engine = (await pairing.findEngine())!;
        await expectLater(
          pairing.pair(engine),
          throwsA(
            isA<PairingException>().having(
              (PairingException e) => e.message,
              'message',
              contains(item.$2),
            ),
          ),
        );
      });
    }
  });

  group('ExtensionPairingController', () {
    test('found -> pair requests host permission and ends paired', () async {
      int changed = 0;
      final ExtensionPairingController controller = ExtensionPairingController(
        pairing: make(),
        host: host,
        serverUrl: 'https://api',
        environment: 'production',
        onConnectionChanged: () async => changed++,
      );
      await controller.refresh();
      expect(controller.status, ExtensionEngineStatus.found);
      await controller.pair();
      expect(host.requestedOrigins, <String>['http://127.0.0.1/*']);
      expect(controller.status, ExtensionEngineStatus.paired);
      expect(changed, 1);
      await controller.unpair();
      expect(host.connection, isNull);
      expect(changed, 2);
      expect(controller.status, ExtensionEngineStatus.found);
      controller.dispose();
    });

    test('no engine -> notFound; denied permission keeps the button', () async {
      final ExtensionPairingController none = ExtensionPairingController(
        pairing: make(ports: <int>{}),
        host: host,
      );
      await none.refresh();
      expect(none.status, ExtensionEngineStatus.notFound);
      none.dispose();

      host.grantOrigins = false;
      final ExtensionPairingController denied = ExtensionPairingController(
        pairing: make(),
        host: host,
      );
      await denied.refresh();
      await denied.pair();
      expect(denied.status, ExtensionEngineStatus.found);
      expect(denied.error, contains('Allow access'));
      expect(host.connection, isNull);
      denied.dispose();
    });

    test('a stored pairing shows as paired without probing', () async {
      host.connection = const ExtensionConnection(
        engineUrl: 'http://127.0.0.1:51516',
        engineToken: 'scp_old',
      );
      final ExtensionPairingController controller = ExtensionPairingController(
        pairing: make(),
        host: host,
      );
      await controller.refresh();
      expect(controller.status, ExtensionEngineStatus.paired);
      expect(requests, isEmpty);
      controller.dispose();
    });

    test('pasting a joining token stores it', () async {
      final ExtensionPairingController controller = ExtensionPairingController(
        pairing: make(ports: <int>{}),
        host: host,
      );
      await controller.connectWithToken(url: 'nonsense', token: '');
      expect(controller.error, isNotNull);
      await controller.connectWithToken(
        url: 'http://192.168.1.5:51515/',
        token: ' joining ',
      );
      expect(host.requestedOrigins, <String>['http://192.168.1.5/*']);
      expect(host.connection?.engineUrl, 'http://192.168.1.5:51515');
      expect(host.connection?.engineToken, 'joining');
      expect(controller.status, ExtensionEngineStatus.paired);
      controller.dispose();
    });
  });
}
