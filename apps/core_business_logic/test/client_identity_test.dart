import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

void main() {
  test('withQuery keeps the token and adds identity, encoded', () {
    const ClientIdentity identity = ClientIdentity(
      type: ClientType.tui,
      name: 'My TUI & co',
      version: '1.0',
    );
    final Uri uri = identity.withQuery(
      Uri.parse('ws://127.0.0.1:1/api/v1/events?token=abc'),
    );
    expect(uri.queryParameters['token'], 'abc');
    expect(uri.queryParameters['client_type'], 'tui');
    expect(uri.queryParameters['client_name'], 'My TUI & co');
    expect(uri.queryParameters['client_version'], '1.0');
  });

  test('null fields are omitted', () {
    const ClientIdentity identity = ClientIdentity(type: ClientType.web);
    final Uri uri = identity.withQuery(Uri.parse('ws://h/e?token=t'));
    expect(uri.queryParameters.keys, containsAll(<String>['token', 'client_type']));
    expect(uri.queryParameters.containsKey('client_name'), isFalse);
    expect(identity.helloData(), <String, dynamic>{'clientType': 'web'});
  });

  test('client sends identity in the query and the hello frame', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Completer<Map<String, String>> query = Completer<Map<String, String>>();
    final Completer<Map<String, dynamic>> hello =
        Completer<Map<String, dynamic>>();
    server.listen((HttpRequest request) async {
      query.complete(request.uri.queryParameters);
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      socket.listen((Object? raw) {
        final Map<String, dynamic> frame =
            jsonDecode(raw! as String) as Map<String, dynamic>;
        if (frame['type'] == 'client.hello') {
          hello.complete(frame['data'] as Map<String, dynamic>);
          socket.add(jsonEncode(<String, dynamic>{
            'type': 'client.hello.ack',
            'data': <String, dynamic>{'clientId': 'x'},
          }));
        }
      });
    });
    final WebSocketEngineClient client = WebSocketEngineClient(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}/api/v1/events?token=t'),
      identity: const ClientIdentity(type: ClientType.tui),
    );
    await client.connect();
    expect((await query.future)['client_type'], 'tui');
    expect((await query.future)['token'], 't');
    expect((await hello.future)['clientType'], 'tui');
    await client.dispose();
    await server.close(force: true);
  });
}
