import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

import 'peer_engine_socket_test.dart' show FakeLink;

const List<ClientToolGroup> _groups = <ClientToolGroup>[
  ClientToolGroup(
    group: 'browser',
    title: 'Browser',
    tools: <ClientToolDefinition>[
      ClientToolDefinition(
        id: 'read_page',
        description: 'Read the page.',
        inputSchema: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'tab_id': <String, dynamic>{'type': 'integer'},
          },
        },
        operation: 'read',
        readOnly: true,
      ),
      ClientToolDefinition(
        id: 'click',
        description: 'Click.',
        inputSchema: <String, dynamic>{'type': 'object'},
        operation: 'update',
        timeoutSeconds: 30,
      ),
    ],
  ),
  ClientToolGroup(
    group: 'webmcp',
    title: 'Page tools',
    tools: <ClientToolDefinition>[],
  ),
];

void main() {
  test('ClientToolGroup parses the host JSON and skips bad entries', () {
    final List<ClientToolGroup> parsed = ClientToolGroup.parseList(
      jsonDecode(
        jsonEncode(<Object?>[
          <String, dynamic>{
            'group': 'browser',
            'title': 'Browser',
            'tools': <Object?>[
              <String, dynamic>{
                'id': 'open_tab',
                'description': 'Open',
                'input_schema': <String, dynamic>{'type': 'object'},
                'operation': 'create',
                'read_only': false,
                'timeout_seconds': 12,
              },
              <String, dynamic>{'description': 'no id'},
            ],
          },
          'junk',
        ]),
      ),
    );
    expect(parsed, hasLength(1));
    expect(parsed.single.tools.single.id, 'open_tab');
    expect(parsed.single.tools.single.operation, 'create');
    expect(parsed.single.tools.single.timeoutSeconds, 12);
  });

  test(
    'PeerEngineSocket sends one tool.register per group and hello identity',
    () async {
      final FakeLink link = FakeLink();
      link.onSend = (String channel, Envelope e) {
        if (e.type == 'client.hello') {
          Future<void>.microtask(
            () => link.receive(
              'control',
              Envelope(
                type: 'client.hello.ack',
                id: e.id,
                data: const <String, dynamic>{},
              ),
            ),
          );
        }
      };
      final PeerEngineSocket socket = PeerEngineSocket(
        linkProvider: () async => link,
        identity: const ClientIdentity(
          type: ClientType.browserExtension,
          name: 'Chromium extension',
          version: '1.2.3',
        ),
      );
      await socket.connect();
      expect(link.sent.first.$2.dataMap, <String, dynamic>{
        'clientType': 'browser_extension',
        'clientName': 'Chromium extension',
        'clientVersion': '1.2.3',
      });
      socket.registerClientTools(_groups);
      final List<Envelope> registers = <Envelope>[
        for (final (String, Envelope) item in link.sent)
          if (item.$2.type == 'tool.register') item.$2,
      ];
      expect(registers, hasLength(2));
      final Map<String, dynamic> first = registers.first.dataMap!;
      expect(first['group'], 'browser');
      expect(first['title'], 'Browser');
      final List<dynamic> tools = first['tools'] as List<dynamic>;
      expect(
        (tools.first as Map<String, dynamic>)['input_schema'],
        isA<Map<String, dynamic>>(),
      );
      expect((tools.first as Map<String, dynamic>)['read_only'], isTrue);
      expect((tools.last as Map<String, dynamic>)['timeout_seconds'], 30);
      // An empty tool list removes the group.
      expect(registers.last.dataMap, <String, dynamic>{
        'group': 'webmcp',
        'title': 'Page tools',
        'tools': <dynamic>[],
      });
      await socket.dispose();
    },
  );

  test(
    'WebSocketEngineClient sends the same tool.register frames and identity',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final Completer<Map<String, String>> query =
          Completer<Map<String, String>>();
      final List<Map<String, dynamic>> registers = <Map<String, dynamic>>[];
      final Completer<void> gotAll = Completer<void>();
      server.listen((HttpRequest request) async {
        query.complete(request.uri.queryParameters);
        final WebSocket socket = await WebSocketTransformer.upgrade(request);
        socket.listen((Object? raw) {
          final Map<String, dynamic> frame =
              jsonDecode(raw! as String) as Map<String, dynamic>;
          if (frame['type'] == 'client.hello') {
            socket.add(
              jsonEncode(<String, dynamic>{
                'v': 1,
                'type': 'client.hello.ack',
                'data': <String, dynamic>{},
              }),
            );
          } else if (frame['type'] == 'tool.register') {
            registers.add(frame);
            if (registers.length == 2) gotAll.complete();
          }
        });
      });
      final WebSocketEngineClient client = WebSocketEngineClient(
        endpoint: Uri.parse(
          'ws://127.0.0.1:${server.port}/api/v1/events?token=t',
        ),
        identity: const ClientIdentity(
          type: ClientType.browserExtension,
          name: 'Chromium extension',
          version: '1.2.3',
        ),
      );
      await client.connect();
      client.registerClientTools(_groups);
      await gotAll.future.timeout(const Duration(seconds: 5));
      final Map<String, String> params = await query.future;
      expect(params['client_type'], 'browser_extension');
      expect(params['client_name'], 'Chromium extension');
      expect(params['client_version'], '1.2.3');
      expect(registers.first['v'], 1);
      expect(
        (registers.first['data'] as Map<String, dynamic>)['group'],
        'browser',
      );
      expect(
        (registers.last['data'] as Map<String, dynamic>)['tools'],
        isEmpty,
      );
      await client.dispose();
      await server.close(force: true);
    },
  );
}
