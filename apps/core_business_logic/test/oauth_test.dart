import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

WireFrame frame(String type, String? id, Map<String, dynamic> data) =>
    WireFrame(type: type, id: id, data: data);

RestEngineClient clientWith(
  List<http.Request> seen,
  http.Response Function(http.Request request) respond,
) => RestEngineClient(
  baseUri: Uri.parse('http://127.0.0.1:1/api/v1/'),
  token: 't',
  client: MockClient((http.Request request) async {
    seen.add(request);
    return respond(request);
  }),
);

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  group('oauth frames', () {
    test('oauth.request parses into OAuthRequested', () {
      final DateTime before = DateTime.now();
      final OAuthRequested event = parseTaskEvent(
        frame('oauth.request', 't1', <String, dynamic>{
          'auth_id': 'a1',
          'tool_uuid': 'u1',
          'tool_name': 'Notion',
          'url': 'https://idp.example/authorize?x=1',
          'redirect_uri': 'http://127.0.0.1:9/api/v1/oauth/callback',
          'expires_in': 600,
          'thread_uuid': 'th1',
        }),
      )! as OAuthRequested;
      final OAuthAuthorization auth = event.authorization;
      expect(auth.authId, 'a1');
      expect(auth.toolUuid, 'u1');
      expect(auth.toolName, 'Notion');
      expect(auth.url, 'https://idp.example/authorize?x=1');
      expect(auth.redirectUri, endsWith('/oauth/callback'));
      expect(auth.threadUuid, 'th1');
      expect(auth.turnId, 't1');
      expect(event.taskId, 't1');
      expect(
        auth.expiresAt!.isAfter(before.add(const Duration(seconds: 599))),
        isTrue,
      );
    });

    test('oauth.request without required fields is ignored', () {
      expect(
        parseTaskEvent(frame('oauth.request', 't1', <String, dynamic>{})),
        isNull,
      );
      expect(
        parseTaskEvent(
          frame('oauth.request', 't1', <String, dynamic>{
            'auth_id': 'a1',
            'tool_uuid': 'u1',
          }),
        ),
        isNull,
        reason: 'no url',
      );
      expect(
        parseTaskEvent(
          frame('oauth.request', 't1', <String, dynamic>{
            'auth_id': 5,
            'tool_uuid': 'u1',
            'url': 'https://x',
          }),
        ),
        isNull,
      );
    });

    test('oauth.resolved parses status and rejects unknown ones', () {
      final OAuthResolved event = parseTaskEvent(
        frame('oauth.resolved', 't1', <String, dynamic>{
          'auth_id': 'a1',
          'tool_uuid': 'u1',
          'status': 'denied',
        }),
      )! as OAuthResolved;
      expect(event.authId, 'a1');
      expect(event.status, OAuthStatus.denied);
      expect(
        parseTaskEvent(
          frame('oauth.resolved', 't1', <String, dynamic>{
            'auth_id': 'a1',
            'tool_uuid': 'u1',
            'status': 'weird',
          }),
        ),
        isNull,
      );
      expect(
        parseTaskEvent(frame('oauth.resolved', 't1', <String, dynamic>{})),
        isNull,
      );
    });
  });

  group('models', () {
    test('ToolRegistryEntry parses oauth fields tolerantly', () {
      final ToolRegistryEntry tool = ToolRegistryEntry.fromJson(
        <String, dynamic>{
          'uuid': 'u1',
          'toolType': 'mcp',
          'authType': 'oauth',
          'oauthClientId': 'cid',
          'oauthScopes': 'a b',
          'oauthConnected': true,
        },
      );
      expect(tool.authType, 'oauth');
      expect(tool.oauthClientId, 'cid');
      expect(tool.oauthScopes, 'a b');
      expect(tool.oauthConnected, isTrue);
      final ToolRegistryEntry plain = ToolRegistryEntry.fromJson(
        <String, dynamic>{'uuid': 'u2', 'oauthConnected': 'yes'},
      );
      expect(plain.oauthConnected, isNull);
      expect(plain.oauthClientId, isNull);
    });

    test('ToolRegistryRequest only sends oauth fields that are set', () {
      expect(const ToolRegistryRequest(name: 'x').toJson(), <String, dynamic>{
        'name': 'x',
      });
      expect(
        const ToolRegistryRequest(
          authType: 'oauth',
          oauthClientId: 'cid',
          oauthClientSecret: 's',
          oauthScopes: 'a b',
        ).toJson(),
        <String, dynamic>{
          'authType': 'oauth',
          'oauthClientId': 'cid',
          'oauthClientSecret': 's',
          'oauthScopes': 'a b',
        },
      );
      final Map<String, dynamic> cleared = const ToolRegistryRequest(
        clearOauthClientSecret: true,
      ).toJson();
      expect(cleared, <String, dynamic>{'clearOauthClientSecret': true});
    });

    test('ToolTestResult.needsAuth defaults to false', () {
      expect(
        ToolTestResult.fromJson(<String, dynamic>{'ok': false}).needsAuth,
        isFalse,
      );
      expect(
        ToolTestResult.fromJson(<String, dynamic>{
          'ok': false,
          'needsAuth': true,
        }).needsAuth,
        isTrue,
      );
    });

    test('OAuthAuthorization.fromJson and ToolAuthorizeResult', () {
      final OAuthAuthorization auth = OAuthAuthorization.fromJson(
        <String, dynamic>{
          'authId': 'a1',
          'toolUuid': 'u1',
          'toolName': 'Notion',
          'url': 'https://x',
          'redirectUri': 'http://127.0.0.1:1/cb',
          'createdAt': '2030-01-01T00:00:00Z',
          'expiresAt': '2030-01-01T00:10:00Z',
        },
      );
      expect(auth.authId, 'a1');
      expect(auth.expiresAt, DateTime.utc(2030, 1, 1, 0, 10));
      expect(
        () => OAuthAuthorization.fromJson(<String, dynamic>{'url': 'x'}),
        throwsFormatException,
      );
      final ToolAuthorizeResult connected = ToolAuthorizeResult.fromJson(
        <String, dynamic>{'authId': null, 'url': null, 'status': 'connected'},
      );
      expect(connected.isConnected, isTrue);
      expect(connected.url, isNull);
    });
  });

  group('client', () {
    test('listPendingOAuth gets the pending list', () async {
      final List<http.Request> seen = <http.Request>[];
      final RestEngineClient client = clientWith(
        seen,
        (_) => json(<Object>[
          <String, dynamic>{
            'authId': 'a1',
            'toolUuid': 'u1',
            'toolName': 'Notion',
            'url': 'https://x',
            'redirectUri': 'http://127.0.0.1:1/cb',
          },
        ]),
      );
      final List<OAuthAuthorization> pending = await client.listPendingOAuth();
      expect(pending.single.toolName, 'Notion');
      expect(seen.single.method, 'GET');
      expect(seen.single.url.path, '/api/v1/oauth/pending');
      expect(seen.single.headers['Authorization'], 'Bearer t');
    });

    test('completeOAuth posts a redirect url, or code and state', () async {
      final List<http.Request> seen = <http.Request>[];
      final RestEngineClient client = clientWith(
        seen,
        (_) => json(<String, dynamic>{'status': 'authorized'}),
      );
      await client.completeOAuth('a 1', redirectUrl: 'http://h/cb?code=c&state=s');
      await client.completeOAuth('a1', code: 'c', state: 's');
      await client.completeOAuth('a1', code: 'c');
      expect(seen[0].method, 'POST');
      expect(seen[0].url.path, '/api/v1/oauth/a%201/complete');
      expect(jsonDecode(seen[0].body), <String, dynamic>{
        'redirectUrl': 'http://h/cb?code=c&state=s',
      });
      expect(jsonDecode(seen[1].body), <String, dynamic>{
        'code': 'c',
        'state': 's',
      });
      expect(jsonDecode(seen[2].body), <String, dynamic>{'code': 'c'});
      expect(
        () => client.completeOAuth('a1'),
        throwsArgumentError,
      );
    });

    test('completeOAuth surfaces the engine error on 400', () async {
      final RestEngineClient client = clientWith(
        <http.Request>[],
        (_) => json(<String, dynamic>{'error': 'state mismatch'}, 400),
      );
      await expectLater(
        client.completeOAuth('a1', code: 'c'),
        throwsA(
          isA<EngineApiException>()
              .having((EngineApiException e) => e.statusCode, 'status', 400)
              .having(
                (EngineApiException e) => e.engineMessage,
                'message',
                'state mismatch',
              ),
        ),
      );
    });

    test('cancelOAuth accepts 204', () async {
      final List<http.Request> seen = <http.Request>[];
      final RestEngineClient client = clientWith(
        seen,
        (_) => http.Response('', 204),
      );
      await client.cancelOAuth('a1');
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/api/v1/oauth/a1/cancel');
    });

    test('authorizeTool and disconnectToolOAuth', () async {
      final List<http.Request> seen = <http.Request>[];
      final RestEngineClient client = clientWith(seen, (http.Request request) {
        if (request.method == 'DELETE') return http.Response('', 204);
        return json(<String, dynamic>{
          'authId': 'a1',
          'url': 'https://idp/authorize',
          'status': 'pending',
        }, 202);
      });
      final ToolAuthorizeResult result = await client.authorizeTool('u1');
      expect(result.authId, 'a1');
      expect(result.url, 'https://idp/authorize');
      expect(result.status, 'pending');
      await client.disconnectToolOAuth('u1');
      expect(seen[0].url.path, '/api/v1/tool-registry/u1/authorize');
      expect(seen[1].method, 'DELETE');
      expect(seen[1].url.path, '/api/v1/tool-registry/u1/oauth');
    });
  });
}
