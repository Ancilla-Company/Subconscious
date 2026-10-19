import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const Map<String, dynamic> _session = <String, dynamic>{
  'signedIn': true,
  'email': 'a@b.c',
};

RestEngineClient clientWith(List<http.Request> seen, {Object body = _session}) =>
    RestEngineClient(
      baseUri: Uri.parse('http://127.0.0.1:1/api/v1/'),
      token: 't',
      client: MockClient((http.Request request) async {
        seen.add(request);
        return http.Response(jsonEncode(body), 200);
      }),
    );

void main() {
  test('login sends device_name and client_id only when given', () async {
    final List<http.Request> seen = <http.Request>[];
    final RestEngineClient client = clientWith(seen);
    await client.login(email: 'a@b.c', password: 'pw');
    expect(jsonDecode(seen.last.body), <String, dynamic>{'email': 'a@b.c', 'password': 'pw'});
    await client.login(
      email: 'a@b.c',
      password: 'pw',
      deviceName: 'Windows PC',
      clientId: 'abc123',
    );
    expect(jsonDecode(seen.last.body), <String, dynamic>{
      'email': 'a@b.c',
      'password': 'pw',
      'device_name': 'Windows PC',
      'client_id': 'abc123',
    });
    expect(seen.last.url.path, '/api/v1/account/login');
  });

  test('getHiveSnapshot returns the whole body and listHiveNodes delegates', () async {
    final List<http.Request> seen = <http.Request>[];
    final RestEngineClient client = clientWith(seen, body: <String, dynamic>{
      'state': 'signed_out',
      'detail': 'Sign in again',
      'signalling': <String, dynamic>{'connected': false},
      'nodes': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'n_a'},
      ],
    });
    final Map<String, dynamic> snapshot = await client.getHiveSnapshot();
    expect(snapshot['state'], 'signed_out');
    expect((snapshot['signalling'] as Map)['connected'], false);
    expect(await client.listHiveNodes(), hasLength(1));
    expect(seen.first.url.path, '/api/v1/hive/nodes');
  });

  test('approveHiveNode and revokeHiveNode use the right paths and bodies', () async {
    final List<http.Request> seen = <http.Request>[];
    final RestEngineClient client = clientWith(seen, body: <String, dynamic>{});
    await client.approveHiveNode('n_x', '1234');
    expect(seen.last.method, 'POST');
    expect(seen.last.url.path, '/api/v1/hive/nodes/n_x/approve');
    expect(jsonDecode(seen.last.body), <String, dynamic>{'sas': '1234'});
    await client.revokeHiveNode('n_x');
    expect(seen.last.method, 'DELETE');
    expect(seen.last.url.path, '/api/v1/hive/nodes/n_x');
  });
}
