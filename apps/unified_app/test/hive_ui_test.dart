import 'dart:convert';

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
}
