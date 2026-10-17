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

/// Runtime whose login succeeds but whose every later server call (device
/// registration / directory fetch) fails with a raw network error.
HiveRuntime _failingFetchRuntime(List<http.Request> requests) => HiveRuntime(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  testWidgets('general settings no longer contains device management', (
    WidgetTester tester,
  ) async {
    final DashboardController dashboard = DashboardController(_noEngine);
    addTearDown(dashboard.dispose);
    final AccountController account = AccountController(
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
      clientProvider: () => null,
    );
    addTearDown(account.dispose);
    await account.restoreSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPanel(controller: account, devicesRuntime: runtime),
        ),
      ),
    );
    await tester.pump();
    expect(account.status, AccountStatus.anonymous);
    expect(find.text('Devices'), findsNothing);
    expect(requests, isEmpty);
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
        clientProvider: () => null,
        serverRuntime: runtime,
      );
      addTearDown(account.dispose);
      await account.restoreSession();
      expect(account.status, AccountStatus.authenticated);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountPanel(controller: account, devicesRuntime: runtime),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Devices'), findsOneWidget);
      expect(find.textContaining("Couldn't load your devices"), findsOneWidget);
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

  testWidgets('devices section asks to sign in when the server session is missing', (
    WidgetTester tester,
  ) async {
    final HiveRuntime runtime = _signedOutRuntime(<http.Request>[]);
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DevicesSection(runtime: runtime)),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Sign in to see your devices'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });
}
