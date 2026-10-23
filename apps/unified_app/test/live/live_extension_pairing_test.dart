@Tags(<String>['live'])
library;

import 'dart:async';
import 'dart:math';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:unified_app/features/extension/extension_connection_resolver.dart';
import 'package:unified_app/features/extension/extension_host.dart';
import 'package:unified_app/features/extension/extension_pairing.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/hive/secure_storage_stores.dart';

import '../extension/fake_extension_host.dart';
import 'live_runtime_support.dart';

/// What a browser does for a page: every request carries the page's `Origin`.
/// The Dart VM sends none, and the real engine refuses a pairing without an
/// extension origin, so the test supplies it like the browser would.
final class _BrowserClient extends http.BaseClient {
  _BrowserClient(this.origin);
  final String origin;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Origin'] = origin;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

String _freshOrigin() {
  final Random random = Random.secure();
  return 'chrome-extension://${String.fromCharCodes(<int>[for (int i = 0; i < 32; i++) 0x61 + random.nextInt(16)])}';
}

/// Live scenario 4 (same device) as the APP does it: the pairing flow against
/// the real server and the real engine, then the connection resolver and the
/// hive runtime on top of the paired local engine.
Future<void> main() async {
  final LiveStack? stack = await LiveStack.resolve();
  final String? skip = stack == null ? liveSkipReason : null;

  test(
    'extension pairing against the real server and engine; the paired token '
    'works for REST and WebSocket, and the extension registers no thin node',
    () async {
      // Bug class: the pairing handshake between extension, server and engine
      // breaks (assertion refused, token not honoured by REST or by the
      // WebSocket path), or an extension paired over loopback still registers
      // its own device (the machine then lists itself twice).
      final LiveStack live = stack!;
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      const FlutterSecureStorage storage = FlutterSecureStorage();
      final FakeExtensionHost host = FakeExtensionHost(
        isExtension: true,
        extensionOrigin: _freshOrigin(),
      );
      useExtensionHost(host);

      // Server login (the extension's account session).
      final ServerAccountClient account = await signIn(live, live.alice);
      addTearDown(account.close);
      final String token = account.accessToken!;
      final Set<String> nodesBefore = (await serverNodes(
        live,
        token,
      )).keys.toSet();

      final _BrowserClient browser = _BrowserClient(host.extensionOrigin);
      addTearDown(browser.close);
      final ExtensionPairing pairing = ExtensionPairing(
        client: browser,
        host: host,
        requestAssertion: account.requestPairingAssertion,
      );

      // `findEngine()` probes the fixed ports 51515/51516 (a developer's own
      // engine could answer there), so the stack's engine is found through the
      // probe it is built on, at its loopback URL from stack.json.
      final FoundEngine? found = await pairing.probe(live.engine.uri);
      expect(found, isNotNull, reason: 'the engine answers its health route');
      expect(found!.nodeId, live.engine.nodeId);

      final ExtensionConnection connection = await pairing.pair(
        found,
        serverUrl: live.serverUrl,
      );
      expect(connection.isPaired, isTrue);
      expect(connection.engineToken, startsWith('scp_'));
      expect(host.connection?.engineToken, connection.engineToken);
      expect(host.connection?.engineUrl, live.engine.uri.toString());
      expect(isLoopbackEngineUrl(connection.engineUrl), isTrue);

      // The paired token works for REST ...
      final RestEngineClient rest = RestEngineClient(
        baseUri: live.engine.uri.replace(path: '/api/v1/'),
        token: connection.engineToken!,
      );
      addTearDown(rest.close);
      expect(await rest.listWorkspaces(), isA<List<Workspace>>());

      // ... and for the WebSocket, as the browser extension client type.
      final WebSocketEngineClient socket = WebSocketEngineClient(
        endpoint: live.engine.uri.replace(
          scheme: 'ws',
          path: '/api/v1/events',
          queryParameters: <String, String>{'token': connection.engineToken!},
        ),
        identity: extensionClientIdentity(host),
      );
      addTearDown(socket.dispose);
      final List<WireFrame> frames = <WireFrame>[];
      final StreamSubscription<WireFrame> subscription = socket.frames.listen(
        frames.add,
      );
      addTearDown(subscription.cancel);
      await socket.connect();
      await eventually<WireFrame>(
        () async {
          for (final WireFrame f in frames) {
            if (f.type == 'client.hello.ack') return f;
          }
          return null;
        },
        what: 'client.hello.ack on the paired WebSocket',
        timeout: const Duration(seconds: 10),
      );
      final WireFrame ack = frames.firstWhere(
        (WireFrame f) => f.type == 'client.hello.ack',
      );
      expect(ack.data?['local'], isTrue, reason: 'loopback = same device');
      await engineNodeIs(
        live.engine,
        live.engine.nodeId,
        (Map<String, dynamic>? n) =>
            n != null && (n['clients'] as List).contains('Browser extension'),
        what: 'the engine lists the extension as a local Browser extension',
      );

      // The wrong token is refused (the pairing did not open the engine up).
      final RestEngineClient stranger = RestEngineClient(
        baseUri: live.engine.uri.replace(path: '/api/v1/'),
        token: 'scp_not_a_real_token',
      );
      addTearDown(stranger.close);
      await expectLater(
        stranger.listWorkspaces(),
        throwsA(isA<EngineApiException>()),
      );

      // The resolver: the paired loopback engine wins and tells the runtime.
      EngineRepository? repository;
      bool announced = false;
      final ServerAccountClient runtimeAccount = ServerAccountClient(
        baseUri: live.serverUri,
        tokenStore: SecureRefreshTokenStore(storage),
      );
      final HiveClient hive = newHiveClient(
        runtimeAccount,
        seedStore: SecureIdentitySeedStore(storage, 0),
        deviceName: host.deviceName,
        platform: 'browser',
      );
      final HiveRuntime runtime = HiveRuntime(
        account: runtimeAccount,
        hive: hive,
        storage: storage,
      );
      addTearDown(() async {
        runtime.dispose();
        await hive.dispose();
        await runtimeAccount.close();
      });
      runtime
        ..expectsLocalEngine = await hasLoopbackPairing(host)
        ..localEngineClient = () async => repository?.rest;
      expect(runtime.expectsLocalEngine, isTrue);

      repository = await resolveExtensionRepository(
        host: host,
        hive: () async => null,
        onLocalEngine: () {
          announced = true;
          runtime.markLocalEngineFound();
        },
      );
      expect(repository, isNotNull, reason: 'the paired engine is reachable');
      expect(announced, isTrue, reason: 'loopback engine => onLocalEngine');
      expect(await repository!.listWorkspaces(), isA<List<Workspace>>());
      addTearDown(repository.socket.dispose);
      addTearDown(repository.rest.close);
      await repository.connect();

      // Signing in now lists devices through the local engine and registers
      // no thin node for this browser.
      await runtime.signIn(
        email: live.alice.email,
        password: live.alice.password,
      );
      expect(runtime.hasLocalFullNode, isTrue);
      expect(hive.started, isFalse, reason: 'no thin hive client was started');
      final NodeView? engineRow = await eventually<NodeView>(
        () async {
          for (final NodeView v in runtime.nodes) {
            if (v.isLocal && v.node.isEngine) return v;
          }
          return null;
        },
        what: "the runtime to list the local engine from the engine's own list",
        timeout: const Duration(seconds: 15),
      );
      expect(engineRow!.node.id, live.engine.nodeId);
      // Registering a thin node needs a node identity; none was ever created
      // for this browser, and the account's list gained nothing from it.
      // (Other live tests share the account, so the list itself is not
      // compared.)
      expect(hive.identity, isNull);
      expect(
        await storage.read(key: 'subconscious.node.identity.v1'),
        isNull,
        reason: 'an extension paired over loopback registers no thin node',
      );
      expect(nodesBefore, contains(live.engine.nodeId));
      expect(
        (await serverNodes(live, token)).keys,
        contains(live.engine.nodeId),
        reason: 'the engine itself stays listed',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
