import 'dart:convert';
import 'dart:io';
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
import 'package:unified_app/features/hive/secure_storage_stores.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('secure stores round trip through the keystore', () async {
    final SecureRefreshTokenStore refresh = SecureRefreshTokenStore();
    expect(await refresh.read(), isNull);
    await refresh.write('r1');
    expect(await refresh.read(), 'r1');
    await refresh.delete();
    expect(await refresh.read(), isNull);

    final SecureIdentitySeedStore seeds = SecureIdentitySeedStore();
    final NodeIdentity identity = await loadOrCreateIdentity(seeds);
    final NodeIdentity again = await loadOrCreateIdentity(seeds);
    expect(again.nodeId, identity.nodeId, reason: 'the seed is persisted');

    final SecurePinStore pins = SecurePinStore('u1');
    await pins.load();
    pins.keys['n_a'] = 'KEY';
    pins.roots.add('n_a');
    await pins.save();
    final SecurePinStore reloaded = await SecurePinStore('u1').load();
    expect(reloaded.keys, <String, String>{'n_a': 'KEY'});
    expect(reloaded.roots, <String>{'n_a'});
    expect((await SecurePinStore('u2').load()).keys, isEmpty);
  });

  testWidgets('devices screen points to the Account page when signed out', (
    WidgetTester tester,
  ) async {
    final HiveRuntime runtime = HiveRuntime(
      account: ServerAccountClient(
        baseUri: Uri.parse('https://api.test'),
        tokenStore: MemoryRefreshTokenStore(),
        client: MockClient(
          (http.Request _) async => http.Response(
            jsonEncode(<String, dynamic>{'detail': 'Invalid email or password'}),
            401,
          ),
        ),
      ),
    );
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(home: NodesPage(runtime: runtime)),
    );
    await tester.pump();
    expect(
      find.text('Sign in from the Account page to see your devices.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsNothing);
  });

  group('device list', () {
    Future<HiveRuntime> signedIn(List<http.Request> requests) async {
      final HiveRuntime runtime = HiveRuntime(
        account: ServerAccountClient(
          baseUri: Uri.parse('https://api.test'),
          tokenStore: MemoryRefreshTokenStore(),
          client: MockClient((http.Request r) async {
            requests.add(r);
            if (r.url.path == '/auth/email/login') {
              return http.Response(
                jsonEncode(<String, dynamic>{
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
                }),
                200,
              );
            }
            throw const SocketException('offline');
          }),
        ),
      );
      addTearDown(runtime.dispose);
      return runtime;
    }

    AccountController accountFor(HiveRuntime runtime) {
      final AccountController account = AccountController(
        session: runtime,
        clientProvider: () => null,
      )..status = AccountStatus.anonymous;
      addTearDown(account.dispose);
      return account;
    }

    NodeView view(String name, {String kind = 'engine', String status = 'active', bool local = false}) =>
        NodeView(
          node: DirectoryNode(
            id: 'n_$name',
            kind: kind,
            name: name,
            platform: 'windows',
            appVersion: '1',
            publicKey: Uint8List(32),
            status: status,
          ),
          trusted: status == 'active',
          online: true,
          isLocal: local,
        );

    testWidgets('device cards have no dot icon or dot separators', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await signedIn(<http.Request>[]);
      final AccountController account = accountFor(runtime);
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      runtime.nodes = <NodeView>[view('Desk', local: true), view('Laptop')];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DevicesSection(account: account)))),
      );
      await tester.pump();
      expect(find.byIcon(Icons.circle), findsNothing);
      expect(find.textContaining('·'), findsNothing);
      expect(find.text('Online, Full node, windows'), findsNWidgets(2));
    });

    testWidgets('clients read "Client" and a signed-in device is never "not verified"', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await signedIn(<http.Request>[]);
      final AccountController account = accountFor(runtime);
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      // A trusted full node exists, so an untrusted active client needs nothing.
      final NodeView phone = NodeView(
        node: DirectoryNode(
          id: 'n_phone',
          kind: 'thin',
          name: 'Phone',
          platform: 'android',
          appVersion: '1',
          publicKey: Uint8List(32),
          status: 'active',
        ),
        trusted: false,
        online: true,
        isLocal: false,
      );
      runtime.nodes = <NodeView>[view('Desk', local: true), phone];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DevicesSection(account: account)))),
      );
      await tester.pump();
      expect(find.text('Online, Client, android'), findsOneWidget);
      expect(find.text('Online, Full node, windows'), findsOneWidget);
      expect(find.textContaining('Thin'), findsNothing);
      expect(find.textContaining('not verified'), findsNothing);
      expect(find.textContaining('Awaiting approval'), findsNothing);

      // No trust root: even without a full node, an active client has no warning.
      runtime.nodes = <NodeView>[phone];
      runtime.notifyListeners();
      await tester.pump();
      expect(find.text('Online, Client, android'), findsOneWidget);
      expect(find.textContaining('Awaiting approval'), findsNothing);
    });

    test('a local full node lists devices (itself included) from the engine', () async {
      final List<http.Request> requests = <http.Request>[];
      final HiveRuntime runtime = await signedIn(requests);
      runtime.hasLocalFullNode = true;
      final List<http.Request> engineRequests = <http.Request>[];
      runtime.localEngineClient = () async => RestEngineClient(
        baseUri: Uri.parse('http://engine.test/api/v1/'),
        token: 't',
        client: MockClient((http.Request r) async {
          engineRequests.add(r);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'nodes': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'n_eng', 'name': 'Laptop', 'kind': 'engine', 'platform': 'windows',
                  'status': 'active', 'trusted': true, 'local': true, 'online': true, 'tier': null,
                },
                <String, dynamic>{
                  'id': 'n_ph', 'name': 'Phone', 'kind': 'thin', 'platform': 'android',
                  'status': 'active', 'trusted': true, 'local': false, 'online': false,
                },
              ],
            }),
            200,
          );
        }),
      );
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      expect(engineRequests.single.url.path, '/api/v1/hive/nodes');
      expect(runtime.nodes.map((NodeView v) => v.node.name), <String>['Laptop', 'Phone']);
      expect(runtime.nodes.first.node.isEngine, isTrue);
      expect(runtime.nodes.first.isLocal, isTrue);
      expect(
        requests.map((http.Request r) => r.url.path),
        <String>['/auth/email/login'],
        reason: 'the GUI itself registers nothing with the server',
      );
    });

    testWidgets('Refresh asks the local engine to reconnect and shows why it is still offline', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await signedIn(<http.Request>[]);
      final AccountController account = accountFor(runtime);
      runtime.hasLocalFullNode = true;
      final List<String> paths = <String>[];
      bool online = false;
      runtime.localEngineClient = () async => RestEngineClient(
        baseUri: Uri.parse('http://engine.test/api/v1/'),
        token: 't',
        client: MockClient((http.Request r) async {
          paths.add('${r.method} ${r.url.path}');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'state': 'running',
              'signalling': <String, dynamic>{
                'connected': online,
                'failures': online ? 0 : 3,
                'last_error': online ? null : 'SSLCertVerificationError',
                'last_error_detail': online ? null : 'certificate has expired',
              },
              'problem': r.url.path.endsWith('/refresh') && !online
                  ? 'Signalling to the server is not connected (certificate has expired).'
                  : null,
              'nodes': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'n_eng', 'name': 'Laptop', 'kind': 'engine', 'platform': 'windows',
                  'status': 'active', 'trusted': true, 'local': true, 'online': online,
                },
              ],
            }),
            200,
          );
        }),
      );
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      account.status = AccountStatus.authenticated;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  DevicesRefreshButton(account: account),
                  DevicesSection(account: account),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // The passive load already says why (never silent).
      expect(find.byKey(const ValueKey<String>('devices-offline-problem')), findsOneWidget);
      expect(find.textContaining('certificate has expired'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('devices-refresh')));
      await tester.pumpAndSettle();
      expect(paths.last, 'POST /api/v1/hive/refresh');
      expect(find.textContaining('Signalling to the server is not connected'), findsOneWidget);

      online = true;
      await tester.tap(find.byKey(const ValueKey<String>('devices-refresh')));
      await tester.pumpAndSettle();
      expect(runtime.offlineProblem, isNull);
      expect(find.byKey(const ValueKey<String>('devices-offline-problem')), findsNothing);
      expect(find.text('Online, Full node, windows'), findsOneWidget);
    });

    test('engineOfflineProblem is quiet while the first attempt runs', () {
      expect(
        engineOfflineProblem(<String, dynamic>{
          'state': 'running',
          'signalling': <String, dynamic>{'connected': false, 'failures': 0},
        }),
        isNull,
      );
      expect(
        engineOfflineProblem(<String, dynamic>{
          'state': 'running',
          'signalling': <String, dynamic>{'connected': true},
        }),
        isNull,
      );
      expect(
        engineOfflineProblem(<String, dynamic>{
          'state': 'running',
          'signalling': <String, dynamic>{
            'connected': false,
            'failures': 2,
            'last_error': 'SSLCertVerificationError',
          },
        }),
        'The engine is not connected to the server (SSLCertVerificationError); 2 failed attempts.',
      );
      expect(
        engineOfflineProblem(<String, dynamic>{'problem': 'Not signed in.'}),
        'Not signed in.',
      );
    });

    testWidgets('signed-in pending device shows no code until the grace period', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await signedIn(<http.Request>[]);
      final AccountController account = accountFor(runtime);
      runtime.approvalGrace = const Duration(seconds: 30);
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      runtime.nodes = <NodeView>[
        view('Desk'),
        view('Phone', kind: 'thin', status: 'pending', local: true),
      ];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DevicesSection(account: account)))),
      );
      await tester.pump();
      expect(find.text('Connecting to your account'), findsOneWidget);
      expect(find.textContaining('Code with'), findsNothing);
      await tester.pump(const Duration(seconds: 31));
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.textContaining('Code with Desk'), findsOneWidget);
    });

    testWidgets('hive-mismatch card resets local hive data after confirmation', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await signedIn(<http.Request>[]);
      final AccountController account = accountFor(runtime);
      final List<http.Request> engineRequests = <http.Request>[];
      bool mismatch = true;
      runtime.localEngineClient = () async => RestEngineClient(
        baseUri: Uri.parse('http://engine.test/api/v1/'),
        token: 't',
        client: MockClient((http.Request r) async {
          engineRequests.add(r);
          if (r.method == 'POST') {
            mismatch = false;
            return http.Response(
              jsonEncode(<String, dynamic>{'reset': true, 'backup': 'subconscious.db.bak-1'}),
              200,
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'state': mismatch ? 'hive_mismatch' : 'signed_out',
              'detail': 'different hive',
              'nodes': <Map<String, dynamic>>[],
            }),
            200,
          );
        }),
      );
      runtime.hasLocalFullNode = true;
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DevicesSection(account: account)))),
      );
      await tester.pump();
      final Finder button = find.byKey(const ValueKey<String>('engine-reset-local-hive'));
      expect(button, findsOneWidget);

      // Cancel leaves the engine untouched.
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engineRequests.where((http.Request r) => r.method == 'POST'), isEmpty);

      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('engine-reset-local-hive-confirm')));
      await tester.pumpAndSettle();
      final http.Request post = engineRequests.singleWhere((http.Request r) => r.method == 'POST');
      expect(post.url.path, '/api/v1/hive/reset-local');
      expect(jsonDecode(post.body), <String, dynamic>{'confirm': true});
      expect(find.byKey(const ValueKey<String>('engine-reset-local-hive')), findsNothing);
    });

    test('a local full node skips thin registration', () async {
      final List<http.Request> requests = <http.Request>[];
      final HiveRuntime runtime = await signedIn(requests);
      runtime.hasLocalFullNode = true;
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      expect(runtime.status, HiveStatus.ready);
      expect(runtime.error, isNull);
      expect(runtime.localNode, isNull);
      expect(
        requests.map((http.Request r) => r.url.path),
        <String>['/auth/email/login'],
        reason: 'no device registration or directory fetch',
      );
    });
  });}
