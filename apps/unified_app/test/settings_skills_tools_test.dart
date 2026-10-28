import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/settings/controller/settings_controller.dart';
import 'package:unified_app/features/settings/presentation/settings_main_panel.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

final class _FakeSocket implements EngineSocket {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _skillJson(
  String uuid,
  String name, {
  String sourceType = 'folder',
  String? source,
  String? instructions,
  bool enabled = true,
  bool valid = true,
  String? error,
  String? alias,
}) => <String, dynamic>{
  'uuid': uuid,
  'name': name,
  'alias': alias,
  'description': null,
  'sourceType': sourceType,
  'source': source,
  'instructions': instructions,
  'enabled': enabled,
  'valid': valid,
  'error': error,
};

Map<String, dynamic> _toolJson(
  String uuid,
  String name, {
  String toolType = 'mcp',
  String? command,
  List<String> args = const <String>[],
  String? endpointUrl,
}) => <String, dynamic>{
  'id': 1,
  'uuid': uuid,
  'name': name,
  'toolType': toolType,
  'status': 'active',
  'command': command,
  'args': args,
  'env': <String, String>{},
  'endpointUrl': endpointUrl,
  'transport': endpointUrl != null ? 'http' : 'stdio',
};

/// A tiny in-memory stand-in for the engine's skills and tool-registry routes.
final class _FakeEngine {
  final List<Map<String, dynamic>> skills = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> tools = <Map<String, dynamic>>[];
  final List<http.Request> requests = <http.Request>[];
  Map<String, dynamic> testResponse = <String, dynamic>{
    'ok': true,
    'tools': <Map<String, String>>[
      <String, String>{
        'name': 'read_file',
        'description': 'Reads a file',
        'operation': 'read',
      },
      <String, String>{
        'name': 'write_file',
        'description': 'Writes a file',
        'operation': 'update',
      },
    ],
    'error': null,
  };
  Map<String, dynamic>? failure;
  int _next = 1;

  http.Request lastWhere(String method, String path) => requests.lastWhere(
    (http.Request r) => r.method == method && r.url.path == path,
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final String path = request.url.path.replaceFirst('/api/v1/', '');
    final List<String> parts = path.split('/');
    if (failure != null && request.method != 'GET') {
      return _json(failure!, 400);
    }
    final bool isSkill = parts.first == 'skills';
    final List<Map<String, dynamic>> store = isSkill ? skills : tools;
    if (parts.length == 3 && parts[2] == 'test') {
      return _json(testResponse, 200);
    }
    if (parts.length == 1) {
      if (request.method == 'GET') return _json(store, 200);
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      final Map<String, dynamic> created = <String, dynamic>{
        ...isSkill
            ? _skillJson('new-${_next++}', body['name'] as String)
            : _toolJson('new-${_next++}', (body['alias'] ?? '') as String),
        ...body,
      };
      store.add(created);
      return _json(created, 201);
    }
    final String uuid = parts[1];
    final int index = store.indexWhere(
      (Map<String, dynamic> item) => item['uuid'] == uuid,
    );
    if (index < 0) return _json(<String, dynamic>{'error': 'missing'}, 404);
    switch (request.method) {
      case 'DELETE':
        store.removeAt(index);
        return http.Response('', 204);
      case 'PUT':
        store[index] = <String, dynamic>{
          ...store[index],
          ...jsonDecode(request.body) as Map<String, dynamic>,
        };
        return _json(store[index], 200);
    }
    return _json(store[index], 200);
  }

  http.Response _json(Object body, int status) => http.Response(
    jsonEncode(body),
    status,
    headers: <String, String>{'content-type': 'application/json'},
  );

  DashboardSettingsController controller() {
    final EngineRepository repository = EngineRepository(
      rest: RestEngineClient(
        baseUri: Uri.parse('http://127.0.0.1:50506/api/v1/'),
        token: 't',
        client: MockClient(handle),
      ),
      socket: _FakeSocket(),
    );
    return DashboardSettingsController(repositoryProvider: () => repository);
  }
}

Future<void> _pumpPanel(
  WidgetTester tester,
  DashboardSettingsController settings,
  SettingsPage page,
) async {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final DashboardController dashboard = DashboardController(_noEngine);
  addTearDown(dashboard.dispose);
  final HiveRuntime session = HiveRuntime(
    account: ServerAccountClient(
      baseUri: Uri.parse('https://api.test'),
      tokenStore: MemoryRefreshTokenStore(),
      client: MockClient((http.Request _) async => http.Response('{}', 401)),
    ),
  );
  addTearDown(session.dispose);
  final AccountController account = AccountController(
    session: session,
    clientProvider: () => null,
  );
  addTearDown(account.dispose);
  addTearDown(settings.dispose);
  settings.activePage = page;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SettingsMainPanel(
          controller: settings,
          dashboardController: dashboard,
          accountController: account,
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => page == SettingsPage.skills
        ? settings.loadSkills()
        : settings.loadTools(),
  );
  await tester.pumpAndSettle();
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

void main() {
  group('controller', () {
    test('openSettingsPage(skills) loads the skills', () async {
      final _FakeEngine engine = _FakeEngine()
        ..skills.add(_skillJson('s1', 'pdf', source: 'C:/pdf'));
      final DashboardSettingsController settings = engine.controller();
      addTearDown(settings.dispose);
      settings.openSettingsPage(SettingsPage.skills);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(settings.skills.single.name, 'pdf');
      expect(settings.isLoadingSkills, isFalse);
    });

    test('saveSkill creates, updates and deleteSkill removes', () async {
      final _FakeEngine engine = _FakeEngine();
      final DashboardSettingsController settings = engine.controller();
      addTearDown(settings.dispose);
      await settings.loadSkills();

      expect(
        await settings.saveSkill(
          request: const SkillRequest(
            name: 'notes',
            sourceType: 'text',
            instructions: 'Be brief',
            enabled: true,
          ),
        ),
        isTrue,
      );
      expect(jsonDecode(engine.lastWhere('POST', '/api/v1/skills').body), {
        'name': 'notes',
        'sourceType': 'text',
        'instructions': 'Be brief',
        'enabled': true,
      });
      expect(settings.skills, hasLength(1));
      final SkillEntry created = settings.skills.single;

      expect(
        await settings.saveSkill(
          existing: created,
          request: const SkillRequest(
            name: 'notes',
            sourceType: 'text',
            instructions: 'Be brief',
            enabled: false,
          ),
        ),
        isTrue,
      );
      expect(settings.skills, hasLength(1));
      expect(settings.skills.single.enabled, isFalse);

      expect(await settings.deleteSkill(settings.skills.single), isTrue);
      expect(settings.skills, isEmpty);
    });

    test('a rejected skill surfaces the engine message', () async {
      final _FakeEngine engine = _FakeEngine()
        ..failure = <String, dynamic>{'error': 'Name is invalid'};
      final DashboardSettingsController settings = engine.controller();
      addTearDown(settings.dispose);
      final bool saved = await settings.saveSkill(
        request: const SkillRequest(name: '!', sourceType: 'text'),
      );
      expect(saved, isFalse);
      expect('${settings.skillsError}', contains('Name is invalid'));
      expect(settings.skills, isEmpty);
    });

    test('testTool stores the result and clears the in-flight flag', () async {
      final _FakeEngine engine = _FakeEngine()
        ..tools.add(_toolJson('t1', 'fs', command: 'npx'));
      final DashboardSettingsController settings = engine.controller();
      addTearDown(settings.dispose);
      await settings.loadTools();
      final Future<ToolTestResult?> pending = settings.testTool(
        settings.tools.single,
      );
      expect(settings.testingToolUuids, contains('t1'));
      final ToolTestResult? result = await pending;
      expect(result?.ok, isTrue);
      expect(settings.testingToolUuids, isEmpty);
      expect(settings.toolTestResults['t1']?.tools, hasLength(2));
      expect(
        engine.lastWhere('POST', '/api/v1/tool-registry/t1/test'),
        isNotNull,
      );
    });

    test('a failing test request sets toolsError and returns null', () async {
      final _FakeEngine engine = _FakeEngine()
        ..tools.add(_toolJson('t1', 'fs', command: 'npx'))
        ..failure = <String, dynamic>{'error': 'cannot launch'};
      final DashboardSettingsController settings = engine.controller();
      addTearDown(settings.dispose);
      await settings.loadTools();
      expect(await settings.testTool(settings.tools.single), isNull);
      expect('${settings.toolsError}', contains('cannot launch'));
      expect(settings.toolTestResults, isEmpty);
    });
  });

  group('skills page', () {
    testWidgets('shows the empty state', (WidgetTester tester) async {
      final _FakeEngine engine = _FakeEngine();
      await _pumpPanel(tester, engine.controller(), SettingsPage.skills);
      expect(
        find.text(
          'No skills yet. Add a folder with a SKILL.md or write instructions directly.',
        ),
        findsOneWidget,
      );
      expect(find.text('New skill'), findsOneWidget);
    });

    testWidgets('lists skills with source and status', (
      WidgetTester tester,
    ) async {
      final _FakeEngine engine = _FakeEngine()
        ..skills.addAll(<Map<String, dynamic>>[
          _skillJson('s1', 'pdf', source: 'C:/skills/pdf', alias: 'PDF tools'),
          _skillJson(
            's2',
            'notes',
            sourceType: 'text',
            instructions: 'Always  answer\nbriefly',
            enabled: false,
          ),
          _skillJson(
            's3',
            'broken',
            source: 'C:/nope',
            valid: false,
            error: 'SKILL.md not found',
          ),
        ]);
      await _pumpPanel(tester, engine.controller(), SettingsPage.skills);
      expect(find.text('PDF tools'), findsOneWidget);
      expect(find.text('Folder · C:/skills/pdf'), findsOneWidget);
      expect(find.text('Text · Always answer briefly'), findsOneWidget);
      expect(find.text('disabled'), findsOneWidget);
      expect(find.text('SKILL.md not found'), findsOneWidget);
    });

    testWidgets('creating a text skill posts the expected JSON', (
      WidgetTester tester,
    ) async {
      final _FakeEngine engine = _FakeEngine();
      await _pumpPanel(tester, engine.controller(), SettingsPage.skills);
      await tester.tap(find.text('New skill'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('Source Type:Folder')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Text').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Letters, digits, . _ - (max 64)'),
        'notes',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Write the skill instructions'),
        'Be brief',
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);

      final http.Request post = engine.lastWhere('POST', '/api/v1/skills');
      expect(jsonDecode(post.body), <String, dynamic>{
        'name': 'notes',
        'sourceType': 'text',
        'instructions': 'Be brief',
        'enabled': false,
      });
      expect(find.text('Text · Be brief'), findsOneWidget);
    });

    testWidgets('creating a folder skill posts the folder path', (
      WidgetTester tester,
    ) async {
      final _FakeEngine engine = _FakeEngine();
      await _pumpPanel(tester, engine.controller(), SettingsPage.skills);
      await tester.tap(find.text('New skill'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Letters, digits, . _ - (max 64)'),
        'pdf',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Filled from SKILL.md when left blank'),
        '  ',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Folder containing SKILL.md'),
        'C:/skills/pdf',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);

      expect(
        jsonDecode(engine.lastWhere('POST', '/api/v1/skills').body),
        <String, dynamic>{
          'name': 'pdf',
          'sourceType': 'folder',
          'source': 'C:/skills/pdf',
          'enabled': true,
        },
      );
    });

    testWidgets('validates required fields without calling the engine', (
      WidgetTester tester,
    ) async {
      final _FakeEngine engine = _FakeEngine();
      await _pumpPanel(tester, engine.controller(), SettingsPage.skills);
      await tester.tap(find.text('New skill'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Name is required.'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Letters, digits, . _ - (max 64)'),
        'pdf',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Folder path is required.'), findsOneWidget);
      expect(
        engine.requests.where((http.Request r) => r.method == 'POST'),
        isEmpty,
      );
    });

    testWidgets('an engine rejection is shown in the editor', (
      WidgetTester tester,
    ) async {
      final _FakeEngine engine = _FakeEngine()
        ..failure = <String, dynamic>{'error': 'Name is invalid'};
      await _pumpPanel(tester, engine.controller(), SettingsPage.skills);
      await tester.tap(find.text('New skill'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Letters, digits, . _ - (max 64)'),
        '!bad',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Folder containing SKILL.md'),
        'C:/x',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);
      expect(find.textContaining('Name is invalid'), findsOneWidget);
    });
  });

  group('tools page', () {
    testWidgets('lists tools with type label and command or url', (
      WidgetTester tester,
    ) async {
      final _FakeEngine engine = _FakeEngine()
        ..tools.addAll(<Map<String, dynamic>>[
          _toolJson('t1', 'fs', command: 'npx'),
          _toolJson('t2', 'remote', endpointUrl: 'https://x.test/mcp'),
          _toolJson('t3', 'git', toolType: 'cli', command: 'git'),
        ]);
      await _pumpPanel(tester, engine.controller(), SettingsPage.tools);
      expect(find.text('MCP server · npx'), findsOneWidget);
      expect(find.text('MCP server · https://x.test/mcp'), findsOneWidget);
      expect(find.text('Command line tool · git'), findsOneWidget);
      expect(
        find.textContaining(
          'Register MCP servers, command line tools and external ACP agents',
        ),
        findsOneWidget,
      );
    });

    testWidgets('creating an MCP stdio tool posts parsed command fields', (
      WidgetTester tester,
    ) async {
      final _FakeEngine engine = _FakeEngine();
      await _pumpPanel(tester, engine.controller(), SettingsPage.tools);
      expect(
        find.text(
          'No configured tools yet. Add one to make it available in policies.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('New tool'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Tool name'),
        'files',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Executable, e.g. npx'),
        'npx',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'One argument per line'),
        '-y\n@modelcontextprotocol/server-filesystem\n\nC:/data',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'KEY=value, one per line'),
        'DEBUG=1\nURL=a=b',
      );
      expect(
        find.text('Not encrypted - do not put secrets here.'),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);

      final Map<String, dynamic> body = jsonDecode(
        engine.lastWhere('POST', '/api/v1/tool-registry').body,
      ) as Map<String, dynamic>;
      expect(body['alias'], 'files');
      expect(body['toolType'], 'mcp');
      expect(body['command'], 'npx');
      expect(body['args'], <String>[
        '-y',
        '@modelcontextprotocol/server-filesystem',
        'C:/data',
      ]);
      expect(body['env'], <String, String>{'DEBUG': '1', 'URL': 'a=b'});
      expect(body.containsKey('endpointUrl'), isFalse);
      expect(body.containsKey('cwd'), isFalse);
    });

    testWidgets('an MCP HTTP tool posts the endpoint and no command', (
      WidgetTester tester,
    ) async {
      final _FakeEngine engine = _FakeEngine();
      await _pumpPanel(tester, engine.controller(), SettingsPage.tools);
      await tester.tap(find.text('New tool'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('Connection:Command (stdio)')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('HTTP URL').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Tool name'),
        'remote',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'https://'),
        'https://x.test/mcp',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);

      final Map<String, dynamic> body = jsonDecode(
        engine.lastWhere('POST', '/api/v1/tool-registry').body,
      ) as Map<String, dynamic>;
      expect(body['endpointUrl'], 'https://x.test/mcp');
      expect(body['toolType'], 'mcp');
      expect(body.containsKey('command'), isFalse);
    });

    testWidgets('validation messages per type', (WidgetTester tester) async {
      final _FakeEngine engine = _FakeEngine();
      await _pumpPanel(tester, engine.controller(), SettingsPage.tools);
      await tester.tap(find.text('New tool'));
      await tester.pumpAndSettle();
      final Finder save = find.widgetWithText(FilledButton, 'Save');

      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Alias is required.'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Tool name'), 'x');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Command is required.'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Executable, e.g. npx'),
        'npx',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'KEY=value, one per line'),
        'NOEQUALS',
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        find.text('Environment lines must look like KEY=value.'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('Tool Type:MCP server')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Command line tool').last);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        find.text('Description is required for command line tools.'),
        findsOneWidget,
      );
      expect(
        engine.requests.where((http.Request r) => r.method == 'POST'),
        isEmpty,
      );
    });

    testWidgets('a CLI tool posts command, args and description', (
      WidgetTester tester,
    ) async {
      final _FakeEngine engine = _FakeEngine();
      await _pumpPanel(tester, engine.controller(), SettingsPage.tools);
      await tester.tap(find.text('New tool'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('Tool Type:MCP server')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Command line tool').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Tool name'),
        'git',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Executable, e.g. npx'),
        'git',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'One argument per line'),
        'status',
      );
      await tester.enterText(
        find.widgetWithText(
          TextField,
          'Tell the model what this tool does and how to call it',
        ),
        'Shows repo status',
      );
      expect(
        find.text('Not encrypted - do not put secrets here.'),
        findsNothing,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);

      final Map<String, dynamic> body = jsonDecode(
        engine.lastWhere('POST', '/api/v1/tool-registry').body,
      ) as Map<String, dynamic>;
      expect(body['toolType'], 'cli');
      expect(body['command'], 'git');
      expect(body['args'], <String>['status']);
      expect(body['description'], 'Shows repo status');
      expect(body.containsKey('env'), isFalse);
    });

    testWidgets('Test shows the connected tools', (WidgetTester tester) async {
      final _FakeEngine engine = _FakeEngine()
        ..tools.add(_toolJson('t1', 'fs', command: 'npx'));
      await _pumpPanel(tester, engine.controller(), SettingsPage.tools);
      await tester.tap(find.text('fs'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await _settle(tester);

      expect(find.text('Connected - 2 tools'), findsOneWidget);
      expect(find.text('read_file'), findsOneWidget);
      expect(find.text('write_file'), findsOneWidget);
      expect(find.text('update'), findsOneWidget);
    });

    testWidgets('a failed test shows the error', (WidgetTester tester) async {
      final _FakeEngine engine = _FakeEngine()
        ..tools.add(_toolJson('t1', 'fs', command: 'npx'))
        ..testResponse = <String, dynamic>{
          'ok': false,
          'tools': <Object>[],
          'error': 'Process exited with code 1',
        };
      await _pumpPanel(tester, engine.controller(), SettingsPage.tools);
      await tester.tap(find.text('fs'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await _settle(tester);

      expect(find.text('Process exited with code 1'), findsOneWidget);
      expect(find.textContaining('Connected'), findsNothing);
    });

    testWidgets('a legacy script tool keeps its own type option', (
      WidgetTester tester,
    ) async {
      final _FakeEngine engine = _FakeEngine()
        ..tools.add(<String, dynamic>{
          ..._toolJson('t1', 'old', toolType: 'script'),
          'scriptPath': 'C:/s.py',
          'scriptLanguage': 'python',
        });
      await _pumpPanel(tester, engine.controller(), SettingsPage.tools);
      expect(find.text('Script (legacy) · C:/s.py'), findsOneWidget);
      await tester.tap(find.text('old'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('Tool Type:Script (legacy)')),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'C:/s.py'), findsOneWidget);
    });
  });
}
