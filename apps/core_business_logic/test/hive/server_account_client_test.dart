import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Map<String, dynamic> authBody({
  String access = 'access-1',
  String? refresh = 'refresh-1',
  int expiresIn = 900,
}) => <String, dynamic>{
  'access_token': access,
  'token_type': 'bearer',
  'expires_in': expiresIn,
  'refresh_token': refresh,
  'user': <String, dynamic>{
    'id': 'u-1',
    'email': 'a@b.c',
    'display_name': 'A',
    'avatar_url': null,
    'connected_providers': <String>[],
  },
};

void main() {
  late List<http.Request> requests;
  late MemoryRefreshTokenStore store;
  late DateTime now;

  ServerAccountClient make(http.Response Function(http.Request) handler) {
    return ServerAccountClient(
      baseUri: Uri.parse('https://api.test'),
      tokenStore: store,
      clock: () => now,
      client: MockClient((http.Request r) async {
        requests.add(r);
        return handler(r);
      }),
    );
  }

  setUp(() {
    requests = <http.Request>[];
    store = MemoryRefreshTokenStore();
    now = DateTime.utc(2025, 1, 1);
  });

  test('email login asks for a native refresh token and stores it', () async {
    final ServerAccountClient client = make(
      (http.Request r) => http.Response(jsonEncode(authBody()), 200),
    );
    final ServerUser user = await client.loginWithEmail(email: 'a@b.c', password: 'pw');
    expect(user.id, 'u-1');
    expect(requests.single.url.toString(), 'https://api.test/auth/email/login?native=true');
    expect(jsonDecode(requests.single.body), <String, dynamic>{'email': 'a@b.c', 'password': 'pw'});
    expect(client.accessToken, 'access-1');
    expect(await store.read(), 'refresh-1');
  });

  test('failed login surfaces the server detail and stores nothing', () async {
    final ServerAccountClient client = make(
      (http.Request r) => http.Response(jsonEncode(<String, dynamic>{'detail': 'Invalid email or password'}), 401),
    );
    await expectLater(
      client.loginWithEmail(email: 'a@b.c', password: 'bad'),
      throwsA(isA<HiveApiException>().having((HiveApiException e) => e.statusCode, 'status', 401)),
    );
    expect(await store.read(), isNull);
    expect(client.isSignedIn, isFalse);
  });

  test('refresh rotates the stored token and is shared by concurrent callers', () async {
    await store.write('refresh-1');
    final ServerAccountClient client = make(
      (http.Request r) => http.Response(
        jsonEncode(<String, dynamic>{
          'access_token': 'access-2',
          'token_type': 'bearer',
          'expires_in': 900,
          'refresh_token': 'refresh-2',
        }),
        200,
      ),
    );
    final List<String?> tokens = await Future.wait(<Future<String?>>[
      client.ensureAccessToken(),
      client.ensureAccessToken(),
    ]);
    expect(tokens, <String?>['access-2', 'access-2']);
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/auth/refresh');
    expect(jsonDecode(requests.single.body), <String, dynamic>{'refresh_token': 'refresh-1'});
    expect(await store.read(), 'refresh-2');
  });

  test('a valid access token is reused until near expiry', () async {
    final ServerAccountClient client = make(
      (http.Request r) => r.url.path.endsWith('login')
          ? http.Response(jsonEncode(authBody(expiresIn: 900)), 200)
          : http.Response(
              jsonEncode(<String, dynamic>{'access_token': 'access-2', 'expires_in': 900, 'refresh_token': 'refresh-2'}),
              200,
            ),
    );
    await client.loginWithEmail(email: 'a@b.c', password: 'pw');
    expect(await client.ensureAccessToken(), 'access-1');
    expect(requests, hasLength(1));
    now = now.add(const Duration(seconds: 890));
    expect(await client.ensureAccessToken(), 'access-2');
    expect(requests, hasLength(2));
  });

  test('a rejected refresh token signs the client out', () async {
    await store.write('stale');
    final ServerAccountClient client = make(
      (http.Request r) => http.Response(jsonEncode(<String, dynamic>{'detail': 'Invalid'}), 401),
    );
    expect(await client.restore(), isFalse);
    expect(await store.read(), isNull);
    expect(client.accessToken, isNull);
  });

  test('restore loads the user from /auth/me', () async {
    await store.write('refresh-1');
    final ServerAccountClient client = make((http.Request r) {
      if (r.url.path == '/auth/refresh') {
        return http.Response(
          jsonEncode(<String, dynamic>{'access_token': 'a2', 'expires_in': 900, 'refresh_token': 'r2'}),
          200,
        );
      }
      expect(r.headers['Authorization'], 'Bearer a2');
      return http.Response(jsonEncode(<String, dynamic>{'id': 'u-9', 'email': 'x@y.z'}), 200);
    });
    expect(await client.restore(), isTrue);
    expect(client.user!.id, 'u-9');
  });

  test('native PKCE: challenge is S256 of the verifier and code exchange posts both', () async {
    final PkcePair pkce = await createPkcePair();
    expect(pkce.verifier.length, inInclusiveRange(43, 128));
    expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(pkce.verifier), isTrue);
    expect(pkce.challenge.length, 43);
    expect(pkce.challenge, b64uEncode(await sha256Bytes(ascii.encode(pkce.verifier))));
    // RFC 7636 appendix B vector.
    expect(
      b64uEncode(await sha256Bytes(ascii.encode('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'))),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );

    final ServerAccountClient client = make((http.Request r) {
      if (r.url.path == '/auth/google/login') {
        return http.Response(jsonEncode(<String, dynamic>{'url': 'https://accounts.example/auth', 'state': 's'}), 200);
      }
      return http.Response(jsonEncode(authBody()), 200);
    });
    final Uri url = await client.beginNativeLogin(
      provider: 'google',
      loopbackRedirect: Uri.parse('http://127.0.0.1:5555/cb'),
      pkce: pkce,
    );
    expect(url.host, 'accounts.example');
    final Map<String, String> q = requests.first.url.queryParameters;
    expect(q['native'], 'true');
    expect(q['code_challenge'], pkce.challenge);
    expect(q['code_challenge_method'], 'S256');
    expect(q['redirect_to'], 'http://127.0.0.1:5555/cb');

    await client.exchangeNativeCode(code: 'c' * 40, codeVerifier: pkce.verifier);
    expect(requests.last.url.path, '/auth/native/token');
    expect(jsonDecode(requests.last.body), <String, dynamic>{'code': 'c' * 40, 'code_verifier': pkce.verifier});
    expect(await store.read(), 'refresh-1');
  });

  test('logout revokes the refresh token and clears local state', () async {
    final ServerAccountClient client = make(
      (http.Request r) => r.url.path == '/auth/logout'
          ? http.Response('', 204)
          : http.Response(jsonEncode(authBody()), 200),
    );
    await client.loginWithEmail(email: 'a@b.c', password: 'pw');
    await client.logout();
    expect(requests.last.url.path, '/auth/logout');
    expect(jsonDecode(requests.last.body), <String, dynamic>{'refresh_token': 'refresh-1'});
    expect(await store.read(), isNull);
    expect(client.accessToken, isNull);
    expect(client.user, isNull);
  });

  group('password reset', () {
    test('request posts the email and leaves the session untouched', () async {
      final ServerAccountClient client = make(
        (http.Request r) => http.Response(jsonEncode(<String, dynamic>{'message': 'Sent.'}), 202),
      );
      expect(await client.requestPasswordReset('a@b.c'), 'Sent.');
      expect(requests.single.url.toString(), 'https://api.test/auth/password-reset/request');
      expect(jsonDecode(requests.single.body), <String, dynamic>{'email': 'a@b.c'});
      expect(client.isSignedIn, isFalse);
      expect(await store.read(), isNull);
    });

    test('confirm posts native=true, stores the tokens and sets the user', () async {
      final ServerAccountClient client = make((http.Request r) => http.Response(jsonEncode(authBody()), 200));
      final ServerUser user = await client.confirmPasswordReset(email: 'a@b.c', code: '123456', newPassword: 'new-pass-1');
      expect(user.id, 'u-1');
      expect(requests.single.url.toString(), 'https://api.test/auth/password-reset/confirm?native=true');
      expect(jsonDecode(requests.single.body), <String, dynamic>{
        'email': 'a@b.c',
        'code': '123456',
        'new_password': 'new-pass-1',
      });
      expect(client.user!.id, 'u-1');
      expect(await store.read(), 'refresh-1');
    });

    for (final int status in <int>[400, 429]) {
      test('confirm surfaces a $status as HiveApiException and stores nothing', () async {
        final ServerAccountClient client = make(
          (http.Request r) => http.Response(jsonEncode(<String, dynamic>{'detail': 'nope'}), status),
        );
        await expectLater(
          client.confirmPasswordReset(email: 'a@b.c', code: '1', newPassword: 'new-pass-1'),
          throwsA(isA<HiveApiException>().having((HiveApiException e) => e.statusCode, 'status', status)),
        );
        expect(await store.read(), isNull);
        expect(client.isSignedIn, isFalse);
      });
    }

    test('request reports a network failure as HiveApiException', () async {
      final ServerAccountClient client = make((http.Request r) => throw http.ClientException('down'));
      await expectLater(client.requestPasswordReset('a@b.c'), throwsA(isA<HiveApiException>()));
    });
  });
}
