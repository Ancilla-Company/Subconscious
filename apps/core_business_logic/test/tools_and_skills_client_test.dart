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

void main() {
  group('ToolRegistryEntry', () {
    test('parses stdio fields and transport', () {
      final ToolRegistryEntry tool = ToolRegistryEntry.fromJson(
        <String, dynamic>{
          'id': 1,
          'uuid': 'u1',
          'name': 'fs',
          'toolType': 'mcp',
          'status': 'active',
          'command': 'npx',
          'args': <String>['-y', 'server'],
          'env': <String, String>{'A': 'b'},
          'cwd': 'C:/work',
          'transport': 'stdio',
        },
      );
      expect(tool.command, 'npx');
      expect(tool.args, <String>['-y', 'server']);
      expect(tool.env, <String, String>{'A': 'b'});
      expect(tool.cwd, 'C:/work');
      expect(tool.transport, 'stdio');
    });

    test('missing fields are null or empty', () {
      final ToolRegistryEntry tool = ToolRegistryEntry.fromJson(
        <String, dynamic>{'uuid': 'u1', 'tool_type': 'cli'},
      );
      expect(tool.toolType, 'cli');
      expect(tool.command, isNull);
      expect(tool.args, isEmpty);
      expect(tool.env, isEmpty);
      expect(tool.transport, isNull);
    });
  });

  group('ToolRegistryRequest', () {
    test('omits nulls and includes command fields', () {
      expect(
        const ToolRegistryRequest(
          name: 'fs',
          toolType: 'mcp',
          command: 'npx',
          args: <String>['a'],
          env: <String, String>{'K': 'v'},
          cwd: 'd',
        ).toJson(),
        <String, dynamic>{
          'name': 'fs',
          'toolType': 'mcp',
          'command': 'npx',
          'args': <String>['a'],
          'env': <String, String>{'K': 'v'},
          'cwd': 'd',
        },
      );
      expect(const ToolRegistryRequest(name: 'x').toJson(), <String, dynamic>{
        'name': 'x',
      });
    });

    test('clear flags send explicit nulls', () {
      final Map<String, dynamic> body = const ToolRegistryRequest(
        toolType: 'mcp',
        endpointUrl: 'https://x',
        clearCommand: true,
      ).toJson();
      expect(body['command'], isNull);
      expect(body.containsKey('command'), isTrue);
      expect(body.containsKey('args'), isTrue);
      expect(const ToolRegistryRequest(clearEndpointUrl: true).toJson(),
          <String, dynamic>{'endpointUrl': null});
    });
  });

  test('ToolTestResult parses success and failure', () {
    final ToolTestResult ok = ToolTestResult.fromJson(<String, dynamic>{
      'ok': true,
      'tools': <Map<String, String>>[
        <String, String>{'name': 'read', 'description': 'd', 'operation': 'read'},
      ],
      'error': null,
    });
    expect(ok.ok, isTrue);
    expect(ok.tools.single.name, 'read');
    final ToolTestResult bad = ToolTestResult.fromJson(<String, dynamic>{
      'ok': false,
      'error': 'boom',
    });
    expect(bad.ok, isFalse);
    expect(bad.tools, isEmpty);
    expect(bad.error, 'boom');
  });

  test('SkillEntry parses and SkillRequest omits nulls', () {
    final SkillEntry skill = SkillEntry.fromJson(<String, dynamic>{
      'uuid': 's1',
      'name': 'pdf',
      'sourceType': 'folder',
      'source': 'C:/skills/pdf',
      'enabled': false,
      'valid': false,
      'error': 'SKILL.md not found',
    });
    expect(skill.sourceType, 'folder');
    expect(skill.enabled, isFalse);
    expect(skill.valid, isFalse);
    expect(skill.error, 'SKILL.md not found');
    expect(
      const SkillRequest(name: 'pdf', sourceType: 'text', instructions: 'Hi')
          .toJson(),
      <String, dynamic>{
        'name': 'pdf',
        'sourceType': 'text',
        'instructions': 'Hi',
      },
    );
  });

  group('client', () {
    test('testTool posts to the test path', () async {
      final List<http.Request> seen = <http.Request>[];
      final RestEngineClient client = clientWith(
        seen,
        (_) => json(<String, dynamic>{
          'ok': true,
          'tools': <Object>[],
          'error': null,
        }),
      );
      final ToolTestResult result = await client.testTool('u 1');
      expect(result.ok, isTrue);
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/api/v1/tool-registry/u%201/test');
    });

    test('skills CRUD hits the expected routes', () async {
      final List<http.Request> seen = <http.Request>[];
      final RestEngineClient client = clientWith(seen, (http.Request r) {
        if (r.method == 'DELETE') return http.Response('', 204);
        if (r.method == 'GET' && r.url.path == '/api/v1/skills') {
          return json(<Object>[
            <String, dynamic>{'uuid': 's1', 'name': 'a', 'sourceType': 'text'},
          ]);
        }
        return json(<String, dynamic>{
          'uuid': 's1',
          'name': 'a',
          'sourceType': 'text',
        }, r.method == 'POST' ? 201 : 200);
      });
      expect(await client.listSkills(), hasLength(1));
      const SkillRequest request = SkillRequest(
        name: 'a',
        sourceType: 'text',
        instructions: 'x',
      );
      expect((await client.createSkill(request)).uuid, 's1');
      expect(jsonDecode(seen.last.body), request.toJson());
      expect((await client.getSkill('s1')).name, 'a');
      await client.updateSkill(uuid: 's1', skill: request);
      expect(seen.last.method, 'PUT');
      expect(seen.last.url.path, '/api/v1/skills/s1');
      await client.deleteSkill('s1');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.url.path, '/api/v1/skills/s1');
    });

    test('a 400 surfaces the engine error message', () async {
      final RestEngineClient client = clientWith(
        <http.Request>[],
        (_) => json(<String, dynamic>{'error': 'Name is invalid'}, 400),
      );
      await expectLater(
        client.createSkill(const SkillRequest(name: '!', sourceType: 'text')),
        throwsA(
          isA<EngineApiException>().having(
            (EngineApiException e) => e.toString(),
            'message',
            contains('Name is invalid'),
          ),
        ),
      );
    });
  });
}
