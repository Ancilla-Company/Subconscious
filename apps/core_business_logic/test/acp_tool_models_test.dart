import 'package:core_business_logic/models/engine_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an ACP registry row keeps its command, environment and permissions', () {
    final ToolRegistryEntry entry = ToolRegistryEntry.fromJson(<String, dynamic>{
      'id': 1,
      'uuid': 'u1',
      'name': 'agent',
      'toolType': 'acp',
      'status': 'active',
      'command': 'kiro-cli',
      'args': <String>['acp'],
      'env': <String, String>{'A': 'b'},
      'permissions': 'allow_all',
    });
    expect(entry.toolType, 'acp');
    expect(entry.command, 'kiro-cli');
    expect(entry.args, <String>['acp']);
    expect(entry.env, <String, String>{'A': 'b'});
    expect(entry.permissions, 'allow_all');
  });

  test('permissions are optional and only sent when set', () {
    expect(
      ToolRegistryEntry.fromJson(<String, dynamic>{
        'id': 1,
        'uuid': 'u1',
        'name': 'x',
        'toolType': 'cli',
        'status': 'active',
      }).permissions,
      isNull,
    );
    expect(const ToolRegistryRequest(alias: 'x').toJson().containsKey('permissions'), isFalse);
    final Map<String, dynamic> json = const ToolRegistryRequest(
      alias: 'Agent',
      toolType: 'acp',
      command: 'kiro-cli',
      args: <String>['acp'],
      permissions: 'read_only',
    ).toJson();
    expect(json['toolType'], 'acp');
    expect(json['permissions'], 'read_only');
    expect(json['args'], <String>['acp']);
  });
}
