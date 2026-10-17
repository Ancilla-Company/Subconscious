import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/account/presentation/account_panel.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';

const Map<String, dynamic> _authBody = <String, dynamic>{
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

HiveRuntime _runtime(
  List<http.Request> requests, {
  int confirmStatus = 200,
  int requestStatus = 202,
}) => HiveRuntime(
  account: ServerAccountClient(
    baseUri: Uri.parse('https://api.test'),
    tokenStore: MemoryRefreshTokenStore(),
    client: MockClient((http.Request r) async {
      requests.add(r);
      switch (r.url.path) {
        case '/auth/password-reset/request':
          return http.Response(
            jsonEncode(<String, dynamic>{'message': 'Sent.'}),
            requestStatus,
          );
        case '/auth/password-reset/confirm':
          return confirmStatus == 200
              ? http.Response(jsonEncode(_authBody), 200)
              : http.Response(
                  jsonEncode(<String, dynamic>{
                    'detail': 'Invalid or expired reset code',
                  }),
                  confirmStatus,
                );
      }
      return http.Response('{}', 401);
    }),
  ),
);

Future<AccountController> _controller(
  WidgetTester tester,
  List<http.Request> requests, {
  int confirmStatus = 200,
  int requestStatus = 202,
}) async {
  final HiveRuntime runtime = _runtime(
    requests,
    confirmStatus: confirmStatus,
    requestStatus: requestStatus,
  );
  addTearDown(runtime.dispose);
  final AccountController account = AccountController(
    session: runtime,
    clientProvider: () => null,
  );
  addTearDown(account.dispose);
  await account.restoreSession();
  return account;
}

Future<void> _pump(WidgetTester tester, AccountController account) async {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: AccountPanel(controller: account)),
    ),
  );
  await tester.pump();
}

Future<void> _openRequestStep(WidgetTester tester) async {
  await tester.tap(find.text('Forgot password?'));
  await tester.pump();
}

Future<void> _reachConfirmStep(WidgetTester tester) async {
  await _openRequestStep(tester);
  await tester.enterText(find.widgetWithText(TextFormField, 'Email address'), 'a@b.c');
  await tester.tap(find.text('Send reset code'));
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  group('AccountController', () {
    test('requestPasswordReset sets the notice and returns the message', () async {
      final List<http.Request> requests = <http.Request>[];
      final HiveRuntime runtime = _runtime(requests);
      addTearDown(runtime.dispose);
      final AccountController account = AccountController(session: runtime, clientProvider: () => null);
      addTearDown(account.dispose);
      expect(await account.requestPasswordReset(email: ' a@b.c '), 'Sent.');
      expect(account.notice, 'Sent.');
      expect(account.error, isNull);
      expect(account.isBusy, isFalse);
      expect(jsonDecode(requests.single.body), <String, dynamic>{'email': 'a@b.c'});
    });

    test('requestPasswordReset maps 429 to a wait message', () async {
      final HiveRuntime runtime = _runtime(<http.Request>[], requestStatus: 429);
      addTearDown(runtime.dispose);
      final AccountController account = AccountController(session: runtime, clientProvider: () => null);
      addTearDown(account.dispose);
      expect(await account.requestPasswordReset(email: 'a@b.c'), isNull);
      expect(account.error, contains('Too many attempts'));
    });

    test('confirmPasswordReset signs in on success', () async {
      final HiveRuntime runtime = _runtime(<http.Request>[]);
      addTearDown(runtime.dispose);
      final AccountController account = AccountController(session: runtime, clientProvider: () => null);
      addTearDown(account.dispose);
      expect(
        await account.confirmPasswordReset(email: 'a@b.c', code: '123456', newPassword: 'new-pass-1'),
        isTrue,
      );
      expect(account.isAuthenticated, isTrue);
    });

    test('confirmPasswordReset maps 400 to an actionable error', () async {
      final HiveRuntime runtime = _runtime(<http.Request>[], confirmStatus: 400);
      addTearDown(runtime.dispose);
      final AccountController account = AccountController(session: runtime, clientProvider: () => null);
      addTearDown(account.dispose);
      expect(
        await account.confirmPasswordReset(email: 'a@b.c', code: '1', newPassword: 'new-pass-1'),
        isFalse,
      );
      expect(account.error, contains('Invalid or expired reset code'));
      expect(account.error, contains('Request a new code'));
      expect(account.isAuthenticated, isFalse);
    });
  });

  group('AccountPanel forgot password', () {
    testWidgets('the link is shown on the sign-in form', (WidgetTester tester) async {
      final AccountController account = await _controller(tester, <http.Request>[]);
      await _pump(tester, account);
      expect(find.text('Forgot password?'), findsOneWidget);
    });

    testWidgets('an invalid email makes no request', (WidgetTester tester) async {
      final List<http.Request> requests = <http.Request>[];
      final AccountController account = await _controller(tester, requests);
      await _pump(tester, account);
      await _openRequestStep(tester);
      await tester.tap(find.text('Send reset code'));
      await tester.pump();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(requests, isEmpty);
    });

    testWidgets('a valid email reaches the code step and disables resend', (WidgetTester tester) async {
      final List<http.Request> requests = <http.Request>[];
      final AccountController account = await _controller(tester, requests);
      await _pump(tester, account);
      await _reachConfirmStep(tester);
      expect(find.text('Code sent to a@b.c'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Reset code'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'New password'), findsOneWidget);
      final Finder resend = find.widgetWithText(TextButton, 'Send a new code in 60s');
      expect(tester.widget<TextButton>(resend).onPressed, isNull);
      expect(requests.single.url.path, '/auth/password-reset/request');
      // Let the cooldown timer finish so no timer is left pending.
      await tester.pump(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('empty code or short password makes no confirm call', (WidgetTester tester) async {
      final List<http.Request> requests = <http.Request>[];
      final AccountController account = await _controller(tester, requests);
      await _pump(tester, account);
      await _reachConfirmStep(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'New password'), 'short');
      await tester.tap(find.text('Reset password'));
      await tester.pump();
      expect(find.text('Enter the code from your email.'), findsOneWidget);
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      expect(requests.where((http.Request r) => r.url.path.endsWith('confirm')), isEmpty);
      await tester.pump(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('success signs the user in', (WidgetTester tester) async {
      final List<http.Request> requests = <http.Request>[];
      final AccountController account = await _controller(tester, requests);
      await _pump(tester, account);
      await _reachConfirmStep(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Reset code'), '123456');
      await tester.enterText(find.widgetWithText(TextFormField, 'New password'), 'new-pass-1');
      await tester.tap(find.text('Reset password'));
      await tester.pump();
      await tester.pump();
      expect(account.isAuthenticated, isTrue);
      expect(find.text('Sign out'), findsOneWidget);
      final http.Request confirm = requests.last;
      expect(confirm.url.path, '/auth/password-reset/confirm');
      expect(jsonDecode(confirm.body)['new_password'], 'new-pass-1');
    });

    testWidgets('a 400 shows the error and keeps the form usable', (WidgetTester tester) async {
      final AccountController account = await _controller(tester, <http.Request>[], confirmStatus: 400);
      await _pump(tester, account);
      await _reachConfirmStep(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Reset code'), '000000');
      await tester.enterText(find.widgetWithText(TextFormField, 'New password'), 'new-pass-1');
      await tester.tap(find.text('Reset password'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Invalid or expired reset code'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Reset password')).onPressed, isNotNull);
      await tester.pump(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Back to sign in works from the request step', (WidgetTester tester) async {
      final AccountController account = await _controller(tester, <http.Request>[]);
      await _pump(tester, account);
      await _openRequestStep(tester);
      expect(find.text('Reset your password'), findsOneWidget);
      await tester.tap(find.text('Back to sign in'));
      await tester.pump();
      expect(find.text('Forgot password?'), findsOneWidget);
      expect(find.text('Reset your password'), findsNothing);
    });

    testWidgets('Back to sign in works from the code step', (WidgetTester tester) async {
      final AccountController account = await _controller(tester, <http.Request>[]);
      await _pump(tester, account);
      await _reachConfirmStep(tester);
      await tester.tap(find.text('Back to sign in'));
      await tester.pump();
      expect(find.text('Forgot password?'), findsOneWidget);
      await tester.pump(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
