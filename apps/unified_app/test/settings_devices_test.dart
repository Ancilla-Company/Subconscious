import 'dart:convert';
import 'dart:io';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/account/presentation/account_panel.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/hive/presentation/nodes_page.dart';
import 'package:unified_app/features/settings/presentation/settings_main_panel.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

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

/// Runtime whose login succeeds but whose every later server call (device
/// registration / directory fetch) fails with a raw network error.
HiveRuntime _failingFetchRuntime(List<http.Request> requests) => HiveRuntime(
  account: ServerAccountClient(
    baseUri: Uri.parse('https://api.test'),
    tokenStore: MemoryRefreshTokenStore(),
    client: MockClient((http.Request r) async {
      requests.add(r);
      if (r.url.path == '/auth/email/login') {
        return http.Response(jsonEncode(_loginBody), 200);
      }
      throw const SocketException('raw-socket-failure-xyz');
    }),
  ),
);

HiveRuntime _signedOutRuntime(List<http.Request> requests) => HiveRuntime(
  account: ServerAccountClient(
    baseUri: Uri.parse('https://api.test'),
    tokenStore: MemoryRefreshTokenStore(),
    client: MockClient((http.Request r) async {
      requests.add(r);
      return http.Response('{}', 401);
    }),
  ),
);

RestEngineClient _engineClient(List<http.Request> requests) => RestEngineClient(
  baseUri: Uri.parse('http://127.0.0.1:1/api/v1/'),
  token: 't',
  client: MockClient((http.Request r) async {
    requests.add(r);
    if (r.url.path.endsWith('/account/login')) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'authenticated': true,
          'user': <String, dynamic>{'id': 'u-1', 'email': 'a@b.c'},
        }),
        200,
      );
    }
    return http.Response('{}', 200);
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  testWidgets('general settings no longer contains device management', (
    WidgetTester tester,
  ) async {
    final DashboardController dashboard = DashboardController(_noEngine);
    addTearDown(dashboard.dispose);
    final HiveRuntime runtime = _signedOutRuntime(<http.Request>[]);
    addTearDown(runtime.dispose);
    final AccountController account = AccountController(
      session: runtime,
      clientProvider: () => null,
    );
    addTearDown(account.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsMainPanel(
            controller: dashboard.settings,
            dashboardController: dashboard,
            accountController: account,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('General Settings'), findsOneWidget);
    expect(find.text('Devices'), findsNothing);
    expect(find.text('Manage devices'), findsNothing);
    expect(find.textContaining("Couldn't load your devices"), findsNothing);
  });

  testWidgets('account page hides devices and never fetches when signed out', (
    WidgetTester tester,
  ) async {
    final List<http.Request> requests = <http.Request>[];
    final HiveRuntime runtime = _signedOutRuntime(requests);
    addTearDown(runtime.dispose);
    final AccountController account = AccountController(
      session: runtime,
      clientProvider: () => null,
    );
    addTearDown(account.dispose);
    await account.restoreSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountPanel(controller: account)),
      ),
    );
    await tester.pump();
    expect(account.status, AccountStatus.anonymous);
    expect(find.text('Devices'), findsNothing);
    expect(find.byType(DevicesSection), findsNothing);
  });

  testWidgets('signing in once shows the devices block with no second form', (
    WidgetTester tester,
  ) async {
    final List<http.Request> requests = <http.Request>[];
    final HiveRuntime runtime = _failingFetchRuntime(requests);
    addTearDown(runtime.dispose);
    final AccountController account = AccountController(
      session: runtime,
      clientProvider: () => null,
    );
    addTearDown(account.dispose);
    await account.restoreSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountPanel(controller: account)),
      ),
    );
    await tester.pump();
    expect(find.byType(TextFormField), findsWidgets, reason: 'one sign-in form');

    await tester.runAsync(
      () => account.signIn(email: 'a@b.c', password: 'password1'),
    );
    await tester.pump();
    expect(account.isAuthenticated, isTrue);
    expect(runtime.isSignedIn, isTrue);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsNothing);
  });

  testWidgets(
    'account page shows a friendly retryable message when the device fetch fails',
    (WidgetTester tester) async {
      final List<http.Request> requests = <http.Request>[];
      final HiveRuntime runtime = _failingFetchRuntime(requests);
      addTearDown(runtime.dispose);
      await runtime.signIn(email: 'a@b.c', password: 'password1');
      expect(runtime.isSignedIn, isTrue);
      expect(runtime.error, isA<HiveApiException>());
      final AccountController account = AccountController(
        session: runtime,
        clientProvider: () => null,
        thinClient: true,
      );
      addTearDown(account.dispose);
      await account.restoreSession();
      expect(account.status, AccountStatus.authenticated);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AccountPanel(controller: account)),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Devices'), findsOneWidget);
      expect(find.textContaining('The server returned 400'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      expect(find.textContaining('raw-socket-failure-xyz'), findsNothing);
      expect(find.textContaining('status 400'), findsNothing);
      expect(find.text('No devices yet.'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('raw-socket-failure-xyz'), findsNothing);
    },
  );

  testWidgets('devices section renders nothing when the account is signed out', (
    WidgetTester tester,
  ) async {
    final List<http.Request> requests = <http.Request>[];
    final HiveRuntime runtime = _signedOutRuntime(requests);
    addTearDown(runtime.dispose);
    final AccountController account = AccountController(
      session: runtime,
      clientProvider: () => null,
    )..status = AccountStatus.anonymous;
    addTearDown(account.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DevicesSection(account: account)),
      ),
    );
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('No devices yet.'), findsNothing);
    expect(requests, isEmpty);
  });

  test('the server session is the source of truth; the engine follows', () async {
    final List<http.Request> serverRequests = <http.Request>[];
    final List<http.Request> engineRequests = <http.Request>[];
    final HiveRuntime runtime = _failingFetchRuntime(serverRequests);
    addTearDown(runtime.dispose);
    final AccountController account = AccountController(
      session: runtime,
      clientProvider: () => _engineClient(engineRequests),
    );
    addTearDown(account.dispose);

    expect(runtime.isSignedIn, isFalse);
    final bool signedIn = await account.signIn(
      email: 'a@b.c',
      password: 'password1',
    );
    expect(signedIn, isTrue);
    expect(account.isAuthenticated, isTrue);
    expect(runtime.isSignedIn, isTrue);
    expect(
      serverRequests.where((http.Request r) => r.url.path == '/auth/email/login'),
      hasLength(1),
    );
    expect(
      engineRequests.where((http.Request r) => r.url.path.endsWith('/account/login')),
      hasLength(1),
      reason: 'the local engine is signed in with the same credentials',
    );
    expect(account.notice, isNull);

    await account.signOut();
    expect(account.isAuthenticated, isFalse);
    expect(runtime.isSignedIn, isFalse);
    expect(
      engineRequests.where((http.Request r) => r.url.path.endsWith('/account/logout')),
      hasLength(1),
    );
  });

  test('a rejected sign-in touches neither the session nor the engine', () async {
    final List<http.Request> serverRequests = <http.Request>[];
    final List<http.Request> engineRequests = <http.Request>[];
    final HiveRuntime runtime = _signedOutRuntime(serverRequests);
    addTearDown(runtime.dispose);
    final AccountController account = AccountController(
      session: runtime,
      clientProvider: () => _engineClient(engineRequests),
    );
    addTearDown(account.dispose);

    expect(await account.signIn(email: 'a@b.c', password: 'nope'), isFalse);
    expect(account.isAuthenticated, isFalse);
    expect(runtime.isSignedIn, isFalse);
    expect(account.error, isNotNull);
    expect(engineRequests, isEmpty);
  });

  test('an unreachable local engine keeps the account signed in and says so', () async {
    final HiveRuntime runtime = _failingFetchRuntime(<http.Request>[]);
    addTearDown(runtime.dispose);
    final AccountController account = AccountController(
      session: runtime,
      clientProvider: () => null,
    );
    addTearDown(account.dispose);

    expect(await account.signIn(email: 'a@b.c', password: 'password1'), isTrue);
    expect(account.isAuthenticated, isTrue);
    expect(account.notice, contains('local engine'));
  });

  test('a thin client never touches an engine', () async {
    final List<http.Request> engineRequests = <http.Request>[];
    final HiveRuntime runtime = _failingFetchRuntime(<http.Request>[]);
    addTearDown(runtime.dispose);
    final AccountController account = AccountController(
      session: runtime,
      clientProvider: () => _engineClient(engineRequests),
      thinClient: true,
    );
    addTearDown(account.dispose);

    expect(await account.signIn(email: 'a@b.c', password: 'password1'), isTrue);
    await account.signOut();
    expect(engineRequests, isEmpty);
    expect(account.serverRuntime, same(runtime));
  });
}
