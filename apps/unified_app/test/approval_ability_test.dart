import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/hive/presentation/nodes_page.dart';

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

NodeView _view(
  String id, {
  String kind = 'thin',
  String status = 'active',
  bool trusted = true,
  bool local = false,
  String? sas,
}) => NodeView(
  node: DirectoryNode(
    id: id,
    kind: kind,
    name: id,
    platform: 'windows',
    appVersion: '',
    publicKey: Uint8List(32),
    status: status,
  ),
  trusted: trusted,
  online: true,
  isLocal: local,
  sas: sas,
);

/// A signed-in runtime whose own thin node has [selfStatus] on the server.
Future<HiveRuntime> _startedRuntime(String selfStatus) async {
  final MemoryIdentitySeedStore seeds = MemoryIdentitySeedStore();
  final NodeIdentity me = await loadOrCreateIdentity(seeds);
  final MockClient mock = MockClient((http.Request r) async {
    if (r.url.path == '/auth/email/login') {
      return http.Response(jsonEncode(_loginBody), 200);
    }
    if (r.method == 'GET' && r.url.path == '/nodes') {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'nodes': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': me.nodeId,
              'public_key': me.publicKeyB64u,
              'kind': 'thin',
              'name': 'Me',
              'platform': 'android',
              'status': selfStatus,
              'online': true,
            },
          ],
        }),
        200,
      );
    }
    return http.Response('{}', 200);
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
  await runtime.signIn(email: 'a@b.c', password: 'password1');
  return runtime;
}

Future<HiveRuntime> _plainRuntime() async {
  final HiveRuntime runtime = HiveRuntime(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  group('approvalAbility', () {
    test('loading before the directory and identity are known', () async {
      final HiveRuntime runtime = await _plainRuntime();
      addTearDown(runtime.dispose);
      expect(runtime.approvalAbility, ApprovalAbility.loading);
      expect(runtime.canApprove, isFalse);
    });

    test('allowed when this thin node is trusted', () async {
      final HiveRuntime runtime = await _startedRuntime('active');
      addTearDown(runtime.dispose);
      expect(runtime.approvalAbility, ApprovalAbility.allowed);
      expect(runtime.canApprove, isTrue);
    });

    test('notTrusted when this thin node is revoked', () async {
      final HiveRuntime runtime = await _startedRuntime('revoked');
      addTearDown(runtime.dispose);
      expect(runtime.approvalAbility, ApprovalAbility.notTrusted);
      expect(runtime.canApprove, isFalse);
    });

    test('webBlocked on the web build, whatever the trust', () async {
      final HiveRuntime runtime = await _startedRuntime('active');
      addTearDown(runtime.dispose);
      runtime.debugIsWeb = true;
      expect(runtime.approvalAbility, ApprovalAbility.webBlocked);
      expect(runtime.canApprove, isFalse);
    });

    test('local engine: no engine row is loading', () async {
      final HiveRuntime runtime = await _plainRuntime();
      addTearDown(runtime.dispose);
      runtime.hasLocalFullNode = true;
      runtime.nodes = <NodeView>[_view('n_phone')];
      expect(runtime.approvalAbility, ApprovalAbility.loading);
    });

    test('local engine: a trusted engine row is viaLocalEngine', () async {
      final HiveRuntime runtime = await _plainRuntime();
      addTearDown(runtime.dispose);
      runtime.hasLocalFullNode = true;
      runtime.nodes = <NodeView>[_view('n_pc', kind: 'engine', local: true)];
      expect(runtime.approvalAbility, ApprovalAbility.viaLocalEngine);
      expect(runtime.canApprove, isTrue);
    });

    test('local engine: an untrusted engine row is engineNotTrusted', () async {
      final HiveRuntime runtime = await _plainRuntime();
      addTearDown(runtime.dispose);
      runtime.hasLocalFullNode = true;
      runtime.nodes = <NodeView>[
        _view('n_pc', kind: 'engine', local: true, trusted: false),
      ];
      expect(runtime.approvalAbility, ApprovalAbility.engineNotTrusted);
      expect(runtime.canApprove, isFalse);
    });

    test('canApprove equals the getter in every state', () async {
      final HiveRuntime runtime = await _plainRuntime();
      addTearDown(runtime.dispose);
      for (final ApprovalAbility state in ApprovalAbility.values) {
        runtime.debugApprovalAbility = state;
        expect(
          runtime.canApprove,
          state == ApprovalAbility.allowed || state == ApprovalAbility.viaLocalEngine,
          reason: state.name,
        );
      }
    });

    test('with a local engine, approve goes to the engine route with its code', () async {
      final HiveRuntime runtime = await _plainRuntime();
      addTearDown(runtime.dispose);
      final List<http.Request> engine = <http.Request>[];
      runtime.hasLocalFullNode = true;
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
                  'id': 'n_pc',
                  'kind': 'engine',
                  'trusted': true,
                  'local': true,
                  'online': true,
                  'status': 'active',
                },
                <String, dynamic>{
                  'id': 'n_new',
                  'kind': 'thin',
                  'trusted': false,
                  'online': true,
                  'status': 'pending',
                  'sas': '123456',
                },
              ],
            }),
            200,
          );
        }),
      );
      await runtime.refresh();
      final NodeView pending = runtime.nodes.firstWhere(
        (NodeView v) => v.node.id == 'n_new',
      );
      expect(await runtime.codeFor(pending.node), '123456');
      await runtime.approve(pending.node);
      final http.Request approve = engine.firstWhere((http.Request r) => r.method == 'POST');
      expect(approve.url.path, '/api/v1/hive/nodes/n_new/approve');
      expect(jsonDecode(approve.body), <String, dynamic>{'sas': '123456'});
      expect(
        runtime.approvalNote,
        'Approval did not change this device. Remove it and sign in on that device again.',
        reason: 'the row is still pending after the refresh',
      );
    });
  });

  group('approval notices', () {
    Future<void> pump(
      WidgetTester tester,
      HiveRuntime runtime,
    ) async {
      final AccountController account = AccountController(
        session: runtime,
        clientProvider: () => null,
        thinClient: true,
      );
      addTearDown(account.dispose);
      await tester.runAsync(account.restoreSession);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: DevicesSection(account: account)),
          ),
        ),
      );
      await tester.pump();
    }

    Future<HiveRuntime> runtimeWith(
      WidgetTester tester, {
      required List<NodeView> nodes,
      ApprovalAbility? ability,
      bool localEngine = false,
    }) async {
      final HiveRuntime runtime = (await tester.runAsync(_plainRuntime))!;
      addTearDown(runtime.dispose);
      runtime.hasLocalFullNode = localEngine;
      runtime.debugApprovalAbility = ability;
      runtime.nodes = nodes;
      return runtime;
    }

    final Finder cannot = find.byKey(const ValueKey<String>('cannot-approve-notice'));
    final Finder engineNotTrusted = find.byKey(
      const ValueKey<String>('engine-not-trusted-notice'),
    );

    testWidgets('hidden with a local engine even when blocked and pending', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await runtimeWith(
        tester,
        localEngine: true,
        ability: ApprovalAbility.notTrusted,
        nodes: <NodeView>[
          _view('n_pc', kind: 'engine', local: true),
          _view('n_new', status: 'pending', trusted: false),
        ],
      );
      await pump(tester, runtime);
      expect(cannot, findsNothing);
    });

    for (final ApprovalAbility state in <ApprovalAbility>[
      ApprovalAbility.loading,
      ApprovalAbility.allowed,
      ApprovalAbility.viaLocalEngine,
    ]) {
      testWidgets('hidden while ${state.name}', (WidgetTester tester) async {
        final HiveRuntime runtime = await runtimeWith(
          tester,
          ability: state,
          nodes: <NodeView>[
            _view('n_me', local: true),
            _view('n_new', status: 'pending', trusted: false),
          ],
        );
        await pump(tester, runtime);
        expect(cannot, findsNothing);
      });
    }

    testWidgets('hidden when nothing is pending', (WidgetTester tester) async {
      final HiveRuntime runtime = await runtimeWith(
        tester,
        ability: ApprovalAbility.notTrusted,
        nodes: <NodeView>[_view('n_me', local: true), _view('n_pc', kind: 'engine')],
      );
      await pump(tester, runtime);
      expect(cannot, findsNothing);
    });

    testWidgets('web with a pending device shows the desktop-app text', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await runtimeWith(
        tester,
        ability: ApprovalAbility.webBlocked,
        nodes: <NodeView>[
          _view('n_me', local: true),
          _view('n_new', status: 'pending', trusted: false),
        ],
      );
      await pump(tester, runtime);
      expect(cannot, findsOneWidget);
      expect(find.text('Approve new devices from the Subconscious desktop app.'), findsOneWidget);
      expect(find.text('Approve'), findsNothing, reason: 'no Approve button when blocked');
    });

    testWidgets('not trusted with a pending device shows the other-device text', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await runtimeWith(
        tester,
        ability: ApprovalAbility.notTrusted,
        nodes: <NodeView>[
          _view('n_me', local: true),
          _view('n_new', status: 'pending', trusted: false),
        ],
      );
      await pump(tester, runtime);
      expect(
        find.text('This device is not approved yet. Approve it from another signed-in device.'),
        findsOneWidget,
      );
    });

    testWidgets('engineNotTrusted shows its own wording and hides the other text', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await runtimeWith(
        tester,
        localEngine: true,
        ability: ApprovalAbility.engineNotTrusted,
        nodes: <NodeView>[
          _view('n_pc', kind: 'engine', local: true, trusted: false),
          _view('n_new', status: 'pending', trusted: false),
        ],
      );
      await pump(tester, runtime);
      expect(engineNotTrusted, findsOneWidget);
      expect(find.text('The local engine is not approved. Sign the engine in again.'), findsOneWidget);
      expect(cannot, findsNothing);
    });

    testWidgets('Approve button and message agree: allowed shows the button only', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await runtimeWith(
        tester,
        ability: ApprovalAbility.allowed,
        nodes: <NodeView>[
          _view('n_me', local: true),
          _view('n_new', status: 'pending', trusted: false),
        ],
      );
      await pump(tester, runtime);
      expect(find.text('Approve'), findsOneWidget);
      expect(cannot, findsNothing);
    });

    testWidgets('a pending device always offers Remove', (WidgetTester tester) async {
      final HiveRuntime runtime = await runtimeWith(
        tester,
        ability: ApprovalAbility.notTrusted,
        nodes: <NodeView>[
          _view('n_me', local: true),
          _view('n_new', status: 'pending', trusted: false),
        ],
      );
      await pump(tester, runtime);
      expect(find.widgetWithText(TextButton, 'Remove'), findsOneWidget);
    });
  });
}
