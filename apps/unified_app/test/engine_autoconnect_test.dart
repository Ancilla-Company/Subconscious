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

/// Signed-in runtime (login only; the hive itself is not started).
Future<HiveRuntime> _runtime() async {
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

  test('a single online engine connects with no user action', () async {
    final HiveRuntime runtime = await _runtime();
    addTearDown(runtime.dispose);
    int attempts = 0;
    runtime.onEngineAvailable = () async => attempts++;
    runtime.nodes = <NodeView>[_engine('a')];
    await runtime.maybeAutoConnect();
    expect(attempts, 1);
  });

  test('several engines and no preference wait for the user', () async {
    final HiveRuntime runtime = await _runtime();
    addTearDown(runtime.dispose);
    int attempts = 0;
    runtime.onEngineAvailable = () async => attempts++;
    runtime.nodes = <NodeView>[_engine('a'), _engine('b')];
    await runtime.maybeAutoConnect();
    expect(attempts, 0);
    expect(runtime.engineChoice.kind, EngineChoiceKind.pick);
  });

  test('an offline preferred engine falls back to the only online one', () async {
    final HiveRuntime runtime = await _runtime();
    addTearDown(runtime.dispose);
    int attempts = 0;
    runtime.onEngineAvailable = () async => attempts++;
    runtime.preferredEngineId = 'b';
    runtime.nodes = <NodeView>[_engine('a'), _engine('b', online: false)];
    await runtime.maybeAutoConnect();
    expect(attempts, 1);
  });

  test('preferred engine coming online triggers a connection', () async {
    final HiveRuntime runtime = await _runtime();
    addTearDown(runtime.dispose);
    int attempts = 0;
    runtime.onEngineAvailable = () async => attempts++;
    runtime.preferredEngineId = 'b';
    runtime.nodes = <NodeView>[_engine('a'), _engine('c'), _engine('b', online: false)];
    await runtime.maybeAutoConnect();
    expect(attempts, 0);
    runtime.nodes = <NodeView>[_engine('a'), _engine('c'), _engine('b')];
    await runtime.maybeAutoConnect();
    expect(attempts, 1);
  });

  test('disconnect stops auto-connect and reconnect resumes it', () async {
    final HiveRuntime runtime = await _runtime();
    addTearDown(runtime.dispose);
    int attempts = 0;
    runtime.onEngineAvailable = () async => attempts++;
    runtime.nodes = <NodeView>[_engine('a')];
    await runtime.disconnectEngine();
    final int afterDisconnect = attempts;
    await runtime.maybeAutoConnect();
    expect(attempts, afterDisconnect);
    expect(runtime.autoConnect, isFalse);
    await runtime.reconnectEngine();
    expect(runtime.autoConnect, isTrue);
    expect(attempts, greaterThan(afterDisconnect));
  });

  test('the explicit choice is cached and reloaded by a new runtime', () async {
    final HiveRuntime first = await _runtime();
    addTearDown(first.dispose);
    await first.selectEngine('b');
    final HiveRuntime second = await _runtime();
    addTearDown(second.dispose);
    second.nodes = <NodeView>[_engine('a'), _engine('b')];
    int attempts = 0;
    second.onEngineAvailable = () async => attempts++;
    await second.maybeAutoConnect();
    expect(second.preferredEngineId, 'b');
    expect(attempts, 1, reason: 'preferred online among several connects');
  });

  Future<void> pumpDevices(WidgetTester tester, HiveRuntime runtime) async {
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

  testWidgets('devices section shows the picker and connects on tap', (
    WidgetTester tester,
  ) async {
    final HiveRuntime runtime = (await tester.runAsync(_runtime))!;
    addTearDown(runtime.dispose);
    final List<String> connectCalls = <String>[];
    runtime.onEngineAvailable = () async => connectCalls.add('go');
    runtime.nodes = <NodeView>[_engine('a'), _engine('b')];
    await pumpDevices(tester, runtime);

    expect(find.text('Choose an engine'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Connect'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(TextButton, 'Connect').last);
    await tester.pump();
    await tester.pump();
    expect(runtime.preferredEngineId, 'b');
    expect(connectCalls, isNotEmpty);
  });

  testWidgets('devices section shows status when no engine is online', (
    WidgetTester tester,
  ) async {
    final HiveRuntime runtime = (await tester.runAsync(_runtime))!;
    addTearDown(runtime.dispose);
    runtime.nodes = <NodeView>[_engine('a', online: false)];
    await pumpDevices(tester, runtime);
    expect(find.text('No engine online'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
  });
}
