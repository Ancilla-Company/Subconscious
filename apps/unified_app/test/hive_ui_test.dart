import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  testWidgets('devices screen asks to sign in when signed out', (
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
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.c');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'bad');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid email or password'), findsOneWidget);
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
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      runtime.nodes = <NodeView>[view('Desk', local: true), view('Laptop')];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DevicesSection(runtime: runtime)))),
      );
      await tester.pump();
      expect(find.byIcon(Icons.circle), findsNothing);
      expect(find.textContaining('·'), findsNothing);
      expect(find.text('Online, Engine, windows'), findsNWidgets(2));
    });

    testWidgets('signed-in pending device shows no code until the grace period', (
      WidgetTester tester,
    ) async {
      final HiveRuntime runtime = await signedIn(<http.Request>[]);
      runtime.approvalGrace = const Duration(seconds: 30);
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      runtime.nodes = <NodeView>[
        view('Desk'),
        view('Phone', kind: 'thin', status: 'pending', local: true),
      ];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DevicesSection(runtime: runtime)))),
      );
      await tester.pump();
      expect(find.text('Connecting to your account'), findsOneWidget);
      expect(find.textContaining('Code with'), findsNothing);
      await tester.pump(const Duration(seconds: 31));
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.textContaining('Code with Desk'), findsOneWidget);
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
