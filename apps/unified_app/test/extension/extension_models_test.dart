import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/extension/extension_host.dart';

import 'fake_extension_host.dart';

void main() {
  test('the default host outside the browser is a no-op', () async {
    final ExtensionHost host = ExtensionHost.instance;
    expect(host.isExtension, isFalse);
    expect(host.toolGroups(), isEmpty);
    expect(await host.getConnection(), isNull);
    expect((await host.callTool('browser', 'x', '{}')).ok, isFalse);
    host.setVisible(true);
    host.onToolGroupsChanged((_) {})();
  });

  group('ExtensionConnection', () {
    test('parses the stored JSON', () {
      final ExtensionConnection? connection = ExtensionConnection.tryParse(
        jsonEncode(<String, dynamic>{
          'engineUrl': 'http://127.0.0.1:51516',
          'engineToken': 'scp_x',
          'clientId': 'c1',
          'expiresAt': '2030-01-01T00:00:00Z',
          'serverUrl': 'https://api.subconscious.chat',
          'environment': 'production',
        }),
      );
      expect(connection, isNotNull);
      expect(connection!.isPaired, isTrue);
      expect(connection.engineUrl, 'http://127.0.0.1:51516');
      expect(connection.environment, 'production');
    });

    test('null, empty and malformed text give no connection', () {
      expect(ExtensionConnection.tryParse('null'), isNull);
      expect(ExtensionConnection.tryParse(''), isNull);
      expect(ExtensionConnection.tryParse('{not json'), isNull);
      expect(ExtensionConnection.tryParse('{}'), isNull);
    });

    test('a server-only record is not paired', () {
      final ExtensionConnection? connection = ExtensionConnection.tryParse(
        '{"serverUrl":"https://s"}',
      );
      expect(connection, isNotNull);
      expect(connection!.isPaired, isFalse);
    });

    test('toJson only writes the fields that are set', () {
      expect(
        const ExtensionConnection(engineToken: 't').toJson(),
        <String, dynamic>{'engineToken': 't'},
      );
    });
  });

  group('tool groups', () {
    test('parseToolGroups reads the host JSON', () {
      final List<ClientToolGroup> groups = parseToolGroups(
        jsonEncode(<Object?>[
          <String, dynamic>{
            'group': 'webmcp',
            'title': 'Page',
            'tools': <Object?>[
              <String, dynamic>{
                'id': 'search',
                'description': 'd',
                'input_schema': <String, dynamic>{'type': 'object'},
                'operation': 'execute',
                'read_only': false,
              },
            ],
          },
        ]),
      );
      expect(groups.single.group, 'webmcp');
      expect(groups.single.tools.single.operation, 'execute');
    });

    test('malformed JSON gives no groups', () {
      expect(parseToolGroups('nope'), isEmpty);
      expect(parseToolGroups(null), isEmpty);
    });
  });

  group('ExtensionToolResult', () {
    test('success and failure shapes', () {
      final ExtensionToolResult ok = ExtensionToolResult.parse(
        '{"ok":true,"result":{"title":"T"}}',
      );
      expect(ok.ok, isTrue);
      expect(ok.result, <String, dynamic>{'title': 'T'});
      final ExtensionToolResult failed = ExtensionToolResult.parse(
        '{"ok":false,"error":"no tab"}',
      );
      expect(failed.ok, isFalse);
      expect(failed.error, 'no tab');
      expect(ExtensionToolResult.parse('garbage').ok, isFalse);
    });
  });

  test('the fake host reports what the app needs', () async {
    final FakeExtensionHost host = FakeExtensionHost(groups: [browserGroup]);
    expect(host.toolGroups().single.group, 'browser');
  });
}
