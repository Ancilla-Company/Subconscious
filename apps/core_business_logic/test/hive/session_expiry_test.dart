import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _json(int status, Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), status);

void main() {
  late MemoryRefreshTokenStore store;
  late List<HiveApiException> expired;

  ServerAccountClient make(http.Response Function(http.Request) handler) {
    return ServerAccountClient(
      baseUri: Uri.parse('https://api.test'),
      tokenStore: store,
      client: MockClient((http.Request r) async => handler(r)),
      onSessionExpired: expired.add,
    );
  }

  setUp(() {
    store = MemoryRefreshTokenStore();
    expired = <HiveApiException>[];
  });

  test('401 on login leaves the client signed out and stores nothing', () async {
    final ServerAccountClient client = make(
      (http.Request r) => _json(401, <String, dynamic>{'detail': 'Invalid email or password'}),
    );
    await expectLater(
      client.loginWithEmail(email: 'a@b.c', password: 'bad'),
      throwsA(isA<HiveApiException>()),
    );
    expect(client.user, isNull);
    expect(client.isSignedIn, isFalse);
    expect(await store.read(), isNull);
  });

  test('a 200 without user or access token is not a login', () async {
    final ServerAccountClient noUser = make(
      (http.Request r) => _json(200, <String, dynamic>{'access_token': 'a-1'}),
    );
    await expectLater(
      noUser.loginWithEmail(email: 'a@b.c', password: 'pw'),
      throwsA(isA<HiveApiException>()),
    );
    expect(noUser.user, isNull);
    final ServerAccountClient noToken = make(
      (http.Request r) => _json(200, <String, dynamic>{
        'user': <String, dynamic>{'id': 'u', 'email': 'a@b.c'},
      }),
    );
    await expectLater(
      noToken.loginWithEmail(email: 'a@b.c', password: 'pw'),
      throwsA(isA<HiveApiException>()),
    );
    expect(noToken.user, isNull);
  });

  test('401 on refresh clears user and token, records the cause, notifies', () async {
    final ServerAccountClient client = make((http.Request r) {
      if (r.url.path == '/auth/email/login') {
        return _json(200, <String, dynamic>{
          'access_token': 'access-1',
          'expires_in': 1,
          'refresh_token': 'refresh-1',
          'user': <String, dynamic>{'id': 'u-1', 'email': 'a@b.c'},
        });
      }
      return _json(401, <String, dynamic>{'detail': 'Invalid or expired refresh token'});
    });
    await client.loginWithEmail(email: 'a@b.c', password: 'pw');
    expect(client.user, isNotNull);

    expect(await client.ensureAccessToken(), isNull);

    expect(client.user, isNull);
    expect(client.isSignedIn, isFalse);
    expect(await store.read(), isNull);
    expect(client.lastAuthError, '401: Invalid or expired refresh token');
    expect(expired, hasLength(1));
    expect(expired.single.statusCode, 401);
    expect(client.lastAuthError, isNot(contains('refresh-1')));
  });

  test('HiveApi calls onUnauthorized once when the retry is still 401', () async {
    int calls = 0;
    final List<String> reasons = <String>[];
    final HiveApi api = HiveApi(
      baseUri: Uri.parse('https://api.test'),
      accessToken: () => 'tok',
      refreshAccessToken: () async {},
      onUnauthorized: (String reason) async => reasons.add(reason),
      client: MockClient((http.Request r) async {
        calls++;
        return _json(401, <String, dynamic>{'detail': 'Not authenticated'});
      }),
    );
    await expectLater(
      api.listNodes(),
      throwsA(isA<HiveApiException>().having((HiveApiException e) => e.statusCode, 'status', 401)),
    );
    expect(calls, 2, reason: 'one retry after refresh');
    expect(reasons, <String>['Not authenticated']);
  });
}
