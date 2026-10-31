import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

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

const Map<String, dynamic> agentJson = <String, dynamic>{
  'uuid': 'a1',
  'name': 'Researcher',
  'description': 'Finds things',
  'instructions': 'Be thorough.',
  'defaultModelId': 'm1',
  'toolsConfig': '{"builtin_enabled":false}',
  'approvalConfig': null,
  'workspaceUuid': 'w1',
  'enabled': false,
  'createdAt': '2026-01-02T03:04:05Z',
  'updatedAt': '2026-01-02T03:04:06Z',
};

void main() {
  group('AgentInfo', () {
    test('parses camelCase and snake_case keys', () {
      final AgentInfo agent = AgentInfo.fromJson(agentJson);
      expect(agent.uuid, 'a1');
      expect(agent.name, 'Researcher');
      expect(agent.toolsConfig, '{"builtin_enabled":false}');
      expect(agent.approvalConfig, isNull);
      expect(agent.workspaceUuid, 'w1');
      expect(agent.isAccountWide, isFalse);
      expect(agent.enabled, isFalse);
      expect(agent.updatedAt, DateTime.utc(2026, 1, 2, 3, 4, 6));

      final AgentInfo snake = AgentInfo.fromJson(<String, dynamic>{
        'uuid': 'a2',
        'name': 'Helper',
        'default_model_id': 'm2',
        'workspace_uuid': null,
      });
      expect(snake.defaultModelId, 'm2');
      expect(snake.isAccountWide, isTrue);
      expect(snake.enabled, isTrue);
    });

    test('requires a uuid', () {
      expect(
        () => AgentInfo.fromJson(<String, dynamic>{'name': 'x'}),
        throwsFormatException,
      );
    });
  });

  group('RestEngineClient agents', () {
    test('lists, filtered by workspace when asked', () async {
      final List<http.Request> seen = <http.Request>[];
      final RestEngineClient client = clientWith(
        seen,
        (http.Request _) => json(<Object>[agentJson]),
      );
      expect((await client.listAgents()).single.name, 'Researcher');
      await client.listAgents(workspaceUuid: 'w 1');
      expect(seen[0].url.path, '/api/v1/agents');
      expect(seen[0].url.queryParameters, isEmpty);
      expect(seen[1].url.queryParameters, <String, String>{
        'workspaceUuid': 'w 1',
      });
      expect(seen[1].headers['Authorization'], 'Bearer t');
    });

    test('create and update send every field, nulls included', () async {
      final List<http.Request> seen = <http.Request>[];
      final RestEngineClient client = clientWith(
        seen,
        (http.Request _) => json(agentJson),
      );
      const AgentRequest request = AgentRequest(name: 'Researcher');
      expect((await client.createAgent(request)).uuid, 'a1');
      await client.updateAgent(uuid: 'a/1', agent: request);

      expect(seen[0].method, 'POST');
      expect(seen[0].url.path, '/api/v1/agents');
      expect(jsonDecode(seen[0].body), <String, dynamic>{
        'name': 'Researcher',
        'description': null,
        'instructions': null,
        'defaultModelId': null,
        'toolsConfig': null,
        'approvalConfig': null,
        'workspaceUuid': null,
        'enabled': true,
      });
      expect(seen[1].method, 'PUT');
      expect(seen[1].url.path, '/api/v1/agents/a%2F1');
    });

    test('gets and deletes by uuid', () async {
      final List<http.Request> seen = <http.Request>[];
      final RestEngineClient client = clientWith(
        seen,
        (http.Request request) => request.method == 'DELETE'
            ? http.Response('', 204)
            : json(agentJson),
      );
      expect((await client.getAgent('a1')).name, 'Researcher');
      await client.deleteAgent('a1');
      expect(seen[0].url.path, '/api/v1/agents/a1');
      expect(seen[1].method, 'DELETE');
      expect(seen[1].url.path, '/api/v1/agents/a1');
    });
  });
}
