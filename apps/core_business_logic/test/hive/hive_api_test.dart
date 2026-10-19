import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'fakes.dart';

HiveApi apiWith(
  http.Response Function(http.Request request, int call) handler,
  List<http.Request> seen, {
  List<Duration>? slept,
}) {
  int calls = 0;
  return HiveApi(
    baseUri: Uri.parse('https://api.test/'),
    accessToken: () => 'access',
    retrySleep: (Duration d) async => slept?.add(d),
    client: MockClient((http.Request request) async {
      seen.add(request);
      return handler(request, calls++);
    }),
  );
}

void main() {
  test('GET retries 502,502 then returns the body (3 attempts)', () async {
    final List<http.Request> seen = <http.Request>[];
    final List<Duration> slept = <Duration>[];
    final HiveApi api = apiWith(
      (http.Request r, int call) => call < 2
          ? http.Response('bad gateway', 502)
          : http.Response(jsonEncode(<String, dynamic>{'nodes': <Object?>[]}), 200),
      seen,
      slept: slept,
    );
    final Map<String, dynamic> body = await api.listNodes();
    expect(body['nodes'], isEmpty);
    expect(seen, hasLength(3));
    expect(slept, <Duration>[const Duration(seconds: 1), const Duration(seconds: 2)]);
  });

  test('GET gives up after the delays are used', () async {
    final List<http.Request> seen = <http.Request>[];
    final HiveApi api = apiWith((http.Request r, int c) => http.Response('', 503), seen);
    await expectLater(
      api.listNodes(),
      throwsA(isA<HiveApiException>().having((HiveApiException e) => e.statusCode, 'status', 503)),
    );
    expect(seen, hasLength(4));
  });

  test('4xx is not retried', () async {
    final List<http.Request> seen = <http.Request>[];
    final HiveApi api = apiWith((http.Request r, int c) => http.Response('{}', 400), seen);
    await expectLater(api.listNodes(), throwsA(isA<HiveApiException>()));
    expect(seen, hasLength(1));
  });

  test('POST is not retried', () async {
    final List<http.Request> seen = <http.Request>[];
    final HiveApi api = apiWith((http.Request r, int c) => http.Response('', 502), seen);
    await expectLater(api.register(<String, dynamic>{}), throwsA(isA<HiveApiException>()));
    expect(seen, hasLength(1));
  });

  test('setParent sends PATCH nodes/{id} with the parent', () async {
    final List<http.Request> seen = <http.Request>[];
    final HiveApi api = apiWith((http.Request r, int c) => http.Response('{}', 200), seen);
    await api.setParent('n_child', 'n_engine');
    expect(seen.single.method, 'PATCH');
    expect(seen.single.url.path, '/nodes/n_child');
    expect(jsonDecode(seen.single.body), <String, dynamic>{'parent_node_id': 'n_engine'});
  });

  group('linkLegacyThinToEngine', () {
    const Map<String, dynamic> loginBody = <String, dynamic>{
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

    Future<(HiveClient, List<http.Request>)> clientFor(
      int patchStatus, {
      bool withSeed = true,
    }) async {
      final List<http.Request> patches = <http.Request>[];
      final MemoryIdentitySeedStore seeds = MemoryIdentitySeedStore();
      if (withSeed) await loadOrCreateIdentity(seeds);
      final MockClient mock = MockClient((http.Request request) async {
        if (request.method == 'PATCH') {
          patches.add(request);
          return http.Response('{}', patchStatus);
        }
        return http.Response(jsonEncode(loginBody), 200);
      });
      final ServerAccountClient account = ServerAccountClient(
        baseUri: Uri.parse('https://api.test/'),
        tokenStore: MemoryRefreshTokenStore(),
        client: mock,
      );
      await account.loginWithEmail(email: 'a@b.c', password: 'pw');
      return (
        HiveClient(
          account: account,
          seedStore: seeds,
          pinStoreFactory: (String _) async => MemoryPinStore(),
          transportFactory: FakeTransportFactory(),
          deviceName: 'd',
          platform: 'windows',
          appVersion: '1',
          httpClient: mock,
        ),
        patches,
      );
    }

    test('returns false without a stored seed and sends nothing', () async {
      final (HiveClient client, List<http.Request> patches) = await clientFor(200, withSeed: false);
      expect(await client.linkLegacyThinToEngine('n_engine'), isFalse);
      expect(patches, isEmpty);
    });

    test('200 gives true and sends PATCH once', () async {
      final (HiveClient client, List<http.Request> patches) = await clientFor(200);
      expect(await client.linkLegacyThinToEngine('n_engine'), isTrue);
      expect(patches, hasLength(1));
      expect(jsonDecode(patches.single.body), <String, dynamic>{'parent_node_id': 'n_engine'});
    });

    test('404 and 405 (old server) and 422 give false', () async {
      for (final int status in <int>[404, 405, 422]) {
        final (HiveClient client, _) = await clientFor(status);
        expect(await client.linkLegacyThinToEngine('n_engine'), isFalse, reason: '$status');
      }
    });

    test('other errors are rethrown', () async {
      final (HiveClient client, _) = await clientFor(500);
      await expectLater(client.linkLegacyThinToEngine('n_engine'), throwsA(isA<HiveApiException>()));
    });
  });
}
