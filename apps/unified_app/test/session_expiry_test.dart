import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('a 401 session expiry signs the UI out with a specific message', () async {
    final HiveRuntime runtime = HiveRuntime(
      account: ServerAccountClient(
        baseUri: Uri.parse('https://api.test'),
        tokenStore: MemoryRefreshTokenStore(),
        client: MockClient((http.Request r) async {
          if (r.url.path == '/auth/email/login') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'access_token': 'a-1',
                'expires_in': 900,
                'refresh_token': 'r-1',
                'user': <String, dynamic>{'id': 'u', 'email': 'a@b.c'},
              }),
              200,
            );
          }
          return http.Response('{}', 401);
        }),
      ),
    );
    addTearDown(runtime.dispose);
    final AccountController controller = AccountController(
      session: runtime,
      clientProvider: () => null,
      thinClient: true,
    );
    addTearDown(controller.dispose);
    await controller.restoreSession();

    await runtime.account.loginWithEmail(email: 'a@b.c', password: 'pw');
    expect(runtime.isSignedIn, isTrue);
    controller.status = AccountStatus.authenticated;

    await runtime.account.expireSession('Invalid or expired refresh token');

    expect(runtime.isSignedIn, isFalse);
    expect(runtime.status, HiveStatus.signedOut);
    expect((runtime.error! as HiveApiException).statusCode, 401);
    expect(controller.status, AccountStatus.anonymous);
    expect(controller.error, AccountController.sessionExpiredMessage);
    expect(runtime.account.lastAuthError, '401: Invalid or expired refresh token');
    expect(controller.error, isNot(contains('r-1')));
  });
}
