import 'dart:convert';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/hive/executor_selection.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';

NodeView _engine(String id, String name) => NodeView(
  node: DirectoryNode(
    id: id,
    kind: 'engine',
    name: name,
    platform: 'windows',
    appVersion: '',
    publicKey: Uint8List(32),
    status: 'active',
    online: true,
  ),
  trusted: true,
  online: true,
  isLocal: false,
);

RestEngineClient _engineReporting(String? nodeId) => RestEngineClient(
  baseUri: Uri.parse('http://engine.test/api/v1/'),
  token: 't',
  client: MockClient(
    (http.Request _) async => http.Response(
      jsonEncode(<String, dynamic>{
        'state': 'running',
        'node_id': nodeId,
        'nodes': <Object>[],
      }),
      200,
    ),
  ),
);

void main() {
  test(
    'an engine reached directly is not offered again as another device',
    () async {
      final HiveRuntime runtime = HiveRuntime()
        ..nodes = <NodeView>[_engine('e1', 'Brian-XPS')]
        ..localEngineClient = () async => _engineReporting('e1');

      // Before the app knows which node it is talking to, the same engine
      // appears twice: as the default and as a directory entry.
      expect(runtime.options.map((ExecutorOption o) => o.name).toList(), <String>[
        'This engine',
        'Brian-XPS',
      ]);

      await runtime.resolveDirectEngine();

      expect(runtime.options.map((ExecutorOption o) => o.name).toList(), <String>[
        'Brian-XPS (home)',
      ]);
    },
  );

  test('a different engine on the account is still listed', () async {
    final HiveRuntime runtime = HiveRuntime()
      ..nodes = <NodeView>[_engine('e1', 'Brian-XPS'), _engine('e2', 'Studio')]
      ..localEngineClient = () async => _engineReporting('e1');

    await runtime.resolveDirectEngine();

    expect(runtime.options.map((ExecutorOption o) => o.name).toList(), <String>[
      'Brian-XPS (home)',
      'Studio',
    ]);
  });

  test('an engine that is not signed in changes nothing', () async {
    final HiveRuntime runtime = HiveRuntime()
      ..nodes = <NodeView>[_engine('e1', 'Brian-XPS')]
      ..localEngineClient = () async => _engineReporting(null);

    await runtime.resolveDirectEngine();

    expect(runtime.directEngineNodeId, isNull);
    expect(runtime.options, hasLength(2));
  });
}
