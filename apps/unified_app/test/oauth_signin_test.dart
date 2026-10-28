import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screen_helpers.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/chat/engine_llm_provider.dart';
import 'package:unified_app/features/chat/presentation/engine_chat_panel.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/dashboard/presentation/views_mobile.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/settings/controller/settings_controller.dart';
import 'package:unified_app/features/settings/presentation/settings_main_panel.dart';

final class _FakeSocket implements EngineSocket {
  final StreamController<WireFrame> controller =
      StreamController<WireFrame>.broadcast(sync: true);

  @override
  bool get isConnected => true;

  @override
  Stream<WireFrame> get frames => controller.stream;

  @override
  Future<void> connect() async {}

  @override
  void registerUiTools() {}

  @override
  Future<void> close() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, dynamic> _toolJson(
  String uuid, {
  String authType = 'oauth',
  bool? connected,
  String? clientId,
  String? scopes,
}) => <String, dynamic>{
  'id': 1,
  'uuid': uuid,
  'name': 'notion',
  'alias': 'Notion',
  'toolType': 'mcp',
  'status': 'active',
  'endpointUrl': 'https://mcp.example/mcp',
  'transport': 'http',
  'authType': authType,
  'oauthClientId': clientId,
  'oauthScopes': scopes,
  'oauthConnected': connected,
};

/// Scripted engine: REST via MockClient, frames via [socket].
final class _Engine {
  final _FakeSocket socket = _FakeSocket();
  final List<http.Request> requests = <http.Request>[];
  List<Map<String, dynamic>> pending = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> tools = <Map<String, dynamic>>[];
  int completeStatus = 200;
  Map<String, dynamic> completeBody = <String, dynamic>{'status': 'authorized'};
  int cancelStatus = 204;
  Map<String, dynamic> authorizeBody = <String, dynamic>{
    'authId': 'auth-9',
    'url': 'https://idp.example/authorize?x=1',
    'status': 'pending',
  };

  http.Request last(String method, String suffix) => requests.lastWhere(
    (http.Request r) => r.method == method && r.url.path.endsWith(suffix),
  );

  bool called(String method, String suffix) => requests.any(
    (http.Request r) => r.method == method && r.url.path.endsWith(suffix),
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final String path = request.url.path;
    if (path.endsWith('/health'))
      return _json(<String, dynamic>{'status': 'ok'});
    if (path.endsWith('/oauth/pending')) return _json(pending);
    if (path.endsWith('/complete')) {
      return _json(completeBody, completeStatus);
    }
    if (path.endsWith('/cancel')) return http.Response('', cancelStatus);
    if (path.endsWith('/authorize')) return _json(authorizeBody, 202);
    if (request.method == 'DELETE' && path.endsWith('/oauth')) {
      tools = <Map<String, dynamic>>[
        for (final Map<String, dynamic> tool in tools)
          <String, dynamic>{...tool, 'oauthConnected': false},
      ];
      return http.Response('', 204);
    }
    if (path.endsWith('/tool-registry')) {
      if (request.method == 'GET') return _json(tools);
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      final Map<String, dynamic> created = <String, dynamic>{
        ..._toolJson('new-1'),
        ...body,
      };
      created.remove('oauthClientSecret');
      tools.add(created);
      return _json(created, 201);
    }
    if (path.endsWith('/test')) {
      return _json(<String, dynamic>{
        'ok': false,
        'needsAuth': true,
        'tools': <Object>[],
        'error': 'Unauthorized',
      });
    }
    return _json(<dynamic>[]);
  }

  EngineRepository repository() => EngineRepository(
    rest: RestEngineClient(
      baseUri: Uri.parse('http://127.0.0.1:50506/api/v1/'),
      token: 't',
      client: MockClient(handle),
    ),
    socket: socket,
  );

  void emit(String type, String? id, Map<String, dynamic> data) =>
      socket.controller.add(WireFrame(type: type, id: id, data: data));

  void emitRequest({
    String authId = 'a1',
    String turn = 'turn-1',
    int expiresIn = 600,
    String tool = 'Notion',
  }) => emit('oauth.request', turn, <String, dynamic>{
    'auth_id': authId,
    'tool_uuid': 'tool-1',
    'tool_name': tool,
    'url': 'https://idp.example/authorize?x=$authId',
    'redirect_uri': 'http://127.0.0.1:9/api/v1/oauth/callback',
    'expires_in': expiresIn,
  });
}

Future<DashboardController> _connected(
  _Engine engine, {
  List<Uri>? launched,
  bool launchResult = true,
}) async {
  final DashboardController controller = DashboardController(
    ({Uri? explicitEndpoint, String? explicitToken}) async =>
        engine.repository(),
    oauthLauncher: (Uri uri) async {
      launched?.add(uri);
      return launchResult;
    },
  );
  await controller.load();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  expect(controller.isConnected, isTrue);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  group('DashboardController oauth', () {
    test(
      'an oauth.request frame becomes pendingOAuth, resolved clears it',
      () async {
        final _Engine engine = _Engine();
        final DashboardController controller = await _connected(engine);
        addTearDown(controller.dispose);

        engine.emitRequest();
        final OAuthAuthorization? auth = controller.pendingOAuth;
        expect(auth?.authId, 'a1');
        expect(auth?.toolName, 'Notion');
        expect(auth?.turnId, 'turn-1');

        // The same prompt from the app-wide broadcast is not queued twice.
        engine.emitRequest();
        engine.emitRequest(authId: 'a2');
        expect(controller.pendingOAuth?.authId, 'a1');

        engine.emit('oauth.resolved', 'turn-1', <String, dynamic>{
          'auth_id': 'a1',
          'tool_uuid': 'tool-1',
          'status': 'authorized',
        });
        expect(controller.pendingOAuth?.authId, 'a2', reason: 'queue advances');
        engine.emit('oauth.resolved', null, <String, dynamic>{
          'auth_id': 'a2',
          'tool_uuid': 'tool-1',
          'status': 'denied',
        });
        expect(controller.pendingOAuth, isNull);
      },
    );

    test('a malformed oauth.request is ignored', () async {
      final _Engine engine = _Engine();
      final DashboardController controller = await _connected(engine);
      addTearDown(controller.dispose);
      engine.emit('oauth.request', 't', <String, dynamic>{'auth_id': 'a1'});
      expect(controller.pendingOAuth, isNull);
    });

    test('the card is dismissed when the sign-in expires', () async {
      final _Engine engine = _Engine();
      final DashboardController controller = await _connected(engine);
      addTearDown(controller.dispose);
      engine.emitRequest(expiresIn: 1);
      expect(controller.pendingOAuth, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(controller.pendingOAuth, isNull);
    });

    test('pending sign-ins are recovered from REST on connect', () async {
      final _Engine engine = _Engine()
        ..pending = <Map<String, dynamic>>[
          <String, dynamic>{
            'authId': 'a7',
            'toolUuid': 'tool-1',
            'toolName': 'Linear',
            'url': 'https://idp.example/a7',
            'redirectUri': 'http://127.0.0.1:9/cb',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 5))
                .toIso8601String(),
          },
          <String, dynamic>{
            'authId': 'old',
            'toolUuid': 'tool-1',
            'toolName': 'Gone',
            'url': 'https://idp.example/old',
            'expiresAt': DateTime.now()
                .toUtc()
                .subtract(const Duration(minutes: 5))
                .toIso8601String(),
          },
        ];
      final DashboardController controller = await _connected(engine);
      addTearDown(controller.dispose);
      expect(controller.pendingOAuth?.authId, 'a7');
      expect(controller.pendingOAuth?.toolName, 'Linear');
      expect(engine.called('GET', '/oauth/pending'), isTrue);
    });

    test(
      'openOAuthSignIn launches the url, and reports a failed launch',
      () async {
        final _Engine engine = _Engine();
        final List<Uri> launched = <Uri>[];
        final DashboardController controller = await _connected(
          engine,
          launched: launched,
        );
        addTearDown(controller.dispose);
        engine.emitRequest();
        await controller.openOAuthSignIn();
        expect(
          launched.single.toString(),
          'https://idp.example/authorize?x=a1',
        );
        expect(controller.oauthError, isNull);

        final List<Uri> none = <Uri>[];
        final DashboardController failing = await _connected(
          engine,
          launched: none,
          launchResult: false,
        );
        addTearDown(failing.dispose);
        engine.emitRequest(authId: 'a5');
        await failing.openOAuthSignIn();
        expect('${failing.oauthError}', contains('Could not open the browser'));
        expect(failing.pendingOAuth, isNotNull);
      },
    );

    test(
      'pasting a full redirect url posts redirectUrl and clears the card',
      () async {
        final _Engine engine = _Engine();
        final DashboardController controller = await _connected(engine);
        addTearDown(controller.dispose);
        engine.emitRequest();
        await controller.completeOAuthFromPaste(
          '  http://127.0.0.1:9/api/v1/oauth/callback?code=c1&state=s1  ',
        );
        final http.Request post = engine.last('POST', '/oauth/a1/complete');
        expect(jsonDecode(post.body), <String, dynamic>{
          'redirectUrl':
              'http://127.0.0.1:9/api/v1/oauth/callback?code=c1&state=s1',
        });
        expect(controller.pendingOAuth, isNull);
        expect(controller.oauthError, isNull);
      },
    );

    test('pasting a bare code posts code', () async {
      final _Engine engine = _Engine();
      final DashboardController controller = await _connected(engine);
      addTearDown(controller.dispose);
      engine.emitRequest();
      await controller.completeOAuthFromPaste('abc123');
      expect(
        jsonDecode(engine.last('POST', '/oauth/a1/complete').body),
        <String, dynamic>{'code': 'abc123'},
      );
      expect(controller.pendingOAuth, isNull);
    });

    test('a 400 keeps the card and shows the engine error', () async {
      final _Engine engine = _Engine()
        ..completeStatus = 400
        ..completeBody = <String, dynamic>{'error': 'state does not match'};
      final DashboardController controller = await _connected(engine);
      addTearDown(controller.dispose);
      engine.emitRequest();
      await controller.completeOAuthFromPaste('http://x/cb?code=c&state=bad');
      expect(controller.pendingOAuth?.authId, 'a1');
      expect(controller.oauthError, 'state does not match');
      expect(controller.isSubmittingOAuth, isFalse);
    });

    test('an empty paste is refused locally', () async {
      final _Engine engine = _Engine();
      final DashboardController controller = await _connected(engine);
      addTearDown(controller.dispose);
      engine.emitRequest();
      await controller.completeOAuthFromPaste('   ');
      expect(controller.oauthError, isNotNull);
      expect(engine.called('POST', '/oauth/a1/complete'), isFalse);
    });

    test('cancelOAuth posts cancel and dismisses the card', () async {
      final _Engine engine = _Engine();
      final DashboardController controller = await _connected(engine);
      addTearDown(controller.dispose);
      engine.emitRequest();
      await controller.cancelOAuth();
      expect(engine.called('POST', '/oauth/a1/cancel'), isTrue);
      expect(controller.pendingOAuth, isNull);
    });

    test('a failed cancel keeps the card with the reason', () async {
      final _Engine engine = _Engine()..cancelStatus = 500;
      final DashboardController controller = await _connected(engine);
      addTearDown(controller.dispose);
      engine.emitRequest();
      await controller.cancelOAuth();
      expect(controller.pendingOAuth, isNotNull);
      expect(controller.oauthError, isNotNull);
    });

    test('a cancel the engine no longer knows (404) still dismisses', () async {
      final _Engine engine = _Engine()..cancelStatus = 404;
      final DashboardController controller = await _connected(engine);
      addTearDown(controller.dispose);
      engine.emitRequest();
      await controller.cancelOAuth();
      expect(controller.pendingOAuth, isNull);
    });
  });

  group('parseOAuthPaste', () {
    test('url, query string and bare code', () {
      expect(parseOAuthPaste('  '), isNull);
      expect(
        parseOAuthPaste('https://h/cb?code=1')?.redirectUrl,
        'https://h/cb?code=1',
      );
      final OAuthPaste query = parseOAuthPaste('code=1&state=2')!;
      expect((query.code, query.state, query.redirectUrl), ('1', '2', null));
      final OAuthPaste bare = parseOAuthPaste('xyz')!;
      expect((bare.code, bare.state), ('xyz', null));
    });
  });

  group('sign-in card', () {
    const OAuthAuthorization auth = OAuthAuthorization(
      authId: 'a1',
      toolUuid: 'tool-1',
      toolName: 'Notion',
      url: 'https://idp.example/a1',
    );

    Widget app({
      OAuthAuthorization? oauth = auth,
      VoidCallback? onOpen,
      ValueChanged<String>? onPaste,
      VoidCallback? onCancel,
      String? error,
      ToolApprovalRequest? approval,
      bool composerEnabled = false,
    }) => MaterialApp(
      home: Scaffold(
        body: EngineChatPanel(
          provider: EngineLlmProvider(),
          isComposerEnabled: composerEnabled,
          oauth: oauth,
          onOAuthOpen: onOpen ?? () {},
          onOAuthPaste: onPaste ?? (String _) {},
          onOAuthCancel: onCancel ?? () {},
          oauthError: error,
          toolApproval: approval,
          onToolApproval: (bool _) {},
        ),
      ),
    );

    final Finder card = find.byKey(const ValueKey<String>('oauth-signin-card'));

    testWidgets('renders title, explanation and buttons', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(app());
      expect(card, findsOneWidget);
      expect(find.text('Sign in to Notion'), findsOneWidget);
      expect(
        find.textContaining(
          'copy the address you end up on and paste it below',
        ),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilledButton, 'Open sign-in page'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Submit'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    });

    testWidgets('is absent without a pending sign-in', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(app(oauth: null));
      expect(card, findsNothing);
    });

    testWidgets('Submit is disabled while empty and sends the trimmed text', (
      WidgetTester tester,
    ) async {
      final List<String> pasted = <String>[];
      await tester.pumpWidget(app(onPaste: pasted.add));
      final Finder submit = find.widgetWithText(FilledButton, 'Submit');
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(submit, warnIfMissed: false);
      expect(pasted, isEmpty);

      final Finder field = find.descendant(
        of: card,
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '   ');
      await tester.pump();
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);

      await tester.enterText(field, '  http://127.0.0.1:9/cb?code=1  ');
      await tester.pump();
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.tap(submit);
      expect(pasted, <String>['http://127.0.0.1:9/cb?code=1']);
    });

    testWidgets('Open and Cancel callbacks fire; error text is shown', (
      WidgetTester tester,
    ) async {
      int opened = 0;
      int cancelled = 0;
      await tester.pumpWidget(
        app(
          onOpen: () => opened++,
          onCancel: () => cancelled++,
          error: 'state does not match',
        ),
      );
      await tester.tap(find.text('Open sign-in page'));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(opened, 1);
      expect(cancelled, 1);
      expect(find.text('state does not match'), findsOneWidget);
    });

    testWidgets('is shown with a disabled composer and above an approval', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        app(
          approval: const ToolApprovalRequest(
            turnId: 't',
            approvalId: 'ap1',
            threadUuid: 'th',
            toolName: 'write_file',
            arguments: <String, dynamic>{'path': 'a'},
            operation: 'update',
          ),
        ),
      );
      expect(card, findsOneWidget);
      expect(find.text('Approval required: write_file'), findsOneWidget);
      expect(
        tester.getTopLeft(card).dy,
        lessThan(
          tester.getTopLeft(find.text('Approval required: write_file')).dy,
        ),
      );
    });

    testWidgets('the mobile view shows the card for a pending sign-in', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(360, 800));
      final _Engine engine = _Engine();
      late final DashboardController dashboard;
      await tester.runAsync(() async {
        dashboard = await _connected(engine);
        engine.emitRequest();
      });
      addTearDown(dashboard.dispose);
      final HiveRuntime runtime = HiveRuntime();
      addTearDown(runtime.dispose);
      final AccountController account = AccountController(
        session: runtime,
        clientProvider: () => null,
      );
      addTearDown(account.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MobileDashboardView(
            controller: dashboard,
            accountController: account,
          ),
        ),
      );
      await tester.pump();
      expect(card, findsOneWidget);
      expect(find.text('Sign in to Notion'), findsOneWidget);
    });
  });

  group('settings', () {
    Future<(DashboardSettingsController, _Engine, List<Uri>)> pump(
      WidgetTester tester, {
      List<Map<String, dynamic>> tools = const <Map<String, dynamic>>[],
      bool launchResult = true,
    }) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final _Engine engine = _Engine()
        ..tools = <Map<String, dynamic>>[...tools];
      final EngineRepository repository = engine.repository();
      final List<Uri> launched = <Uri>[];
      final DashboardSettingsController settings = DashboardSettingsController(
        repositoryProvider: () => repository,
        urlLauncher: (Uri uri) async {
          launched.add(uri);
          return launchResult;
        },
      );
      addTearDown(settings.dispose);
      final DashboardController dashboard = DashboardController(
        ({Uri? explicitEndpoint, String? explicitToken}) async => null,
      );
      addTearDown(dashboard.dispose);
      final HiveRuntime session = HiveRuntime();
      addTearDown(session.dispose);
      final AccountController account = AccountController(
        session: session,
        clientProvider: () => null,
      );
      addTearDown(account.dispose);
      settings.activePage = SettingsPage.tools;
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
      await tester.runAsync(settings.loadTools);
      await tester.pumpAndSettle();
      return (settings, engine, launched);
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }

    Future<void> chooseOAuthForNewHttpTool(WidgetTester tester) async {
      await tester.tap(find.text('New tool'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('Connection:Command (stdio)')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('HTTP URL').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('Authentication:None')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('OAuth').last);
      await tester.pumpAndSettle();
    }

    testWidgets('OAuth shows the extra fields; other types do not', (
      WidgetTester tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('New tool'));
      await tester.pumpAndSettle();
      expect(find.text('Authentication'), findsNothing, reason: 'stdio');
      await tester.tap(
        find.byKey(const ValueKey<String>('Connection:Command (stdio)')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('HTTP URL').last);
      await tester.pumpAndSettle();
      expect(find.text('Client ID (optional)'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey<String>('Authentication:None')),
      );
      await tester.pumpAndSettle();
      expect(find.text('None'), findsWidgets);
      expect(find.text('API key'), findsWidgets);
      await tester.tap(find.text('OAuth').last);
      await tester.pumpAndSettle();

      expect(find.text('Client ID (optional)'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Leave blank to register automatically'),
        findsOneWidget,
      );
      expect(find.text('Client secret (optional)'), findsOneWidget);
      expect(
        find.text('Stored encrypted. Leave blank to keep the saved secret.'),
        findsOneWidget,
      );
      expect(find.text('Scopes (optional)'), findsOneWidget);
      final TextField secret = tester.widget<TextField>(
        find.byWidgetPredicate((Widget w) => w is TextField && w.obscureText),
      );
      expect(secret.obscureText, isTrue);
      expect(find.text('Connect'), findsNothing, reason: 'tool not saved yet');
    });

    testWidgets('creating an OAuth tool posts authType, client id and scopes', (
      WidgetTester tester,
    ) async {
      final (DashboardSettingsController settings, _Engine engine, _) =
          await pump(tester);
      await chooseOAuthForNewHttpTool(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Tool name'),
        'Notion',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'https://'),
        'https://mcp.example/mcp',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Leave blank to register automatically'),
        'client-1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Space separated'),
        'read write',
      );
      await tester.enterText(
        find.byWidgetPredicate((Widget w) => w is TextField && w.obscureText),
        'shh-secret',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);

      final Map<String, dynamic> body = jsonDecode(
        engine.last('POST', '/tool-registry').body,
      ) as Map<String, dynamic>;
      expect(body['authType'], 'oauth');
      expect(body['toolType'], 'mcp');
      expect(body['endpointUrl'], 'https://mcp.example/mcp');
      expect(body['oauthClientId'], 'client-1');
      expect(body['oauthScopes'], 'read write');
      expect(body['oauthClientSecret'], 'shh-secret');
      expect(body.containsKey('clearOauthClientSecret'), isFalse);
      // The secret is write-only: nothing the engine returns echoes it.
      expect(settings.tools.single.oauthClientId, 'client-1');
      expect(find.textContaining('shh-secret'), findsNothing);
    });

    testWidgets('a blank client id and scopes are not sent', (
      WidgetTester tester,
    ) async {
      final (_, _Engine engine, _) = await pump(tester);
      await chooseOAuthForNewHttpTool(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Tool name'),
        'Notion',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'https://'),
        'https://mcp.example/mcp',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      final Map<String, dynamic> body = jsonDecode(
        engine.last('POST', '/tool-registry').body,
      ) as Map<String, dynamic>;
      expect(body['authType'], 'oauth');
      expect(body.containsKey('oauthClientId'), isFalse);
      expect(body.containsKey('oauthClientSecret'), isFalse);
      expect(body.containsKey('oauthScopes'), isFalse);
    });

    testWidgets('an existing tool never shows its saved secret', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        tools: <Map<String, dynamic>>[
          <String, dynamic>{
            ..._toolJson('tool-1', connected: false, clientId: 'cid'),
            'oauthClientSecret': 'leaked-secret',
          },
        ],
      );
      await tester.tap(find.text('Notion'));
      await tester.pumpAndSettle();
      expect(find.text('cid'), findsOneWidget);
      expect(find.textContaining('leaked-secret'), findsNothing);
      final TextField secret = tester.widget<TextField>(
        find.byWidgetPredicate((Widget w) => w is TextField && w.obscureText),
      );
      expect(secret.controller?.text, isEmpty);
    });

    testWidgets('Connect opens the page, then a pasted address completes it', (
      WidgetTester tester,
    ) async {
      final (
        DashboardSettingsController settings,
        _Engine engine,
        List<Uri> launched,
      ) = await pump(
        tester,
        tools: <Map<String, dynamic>>[_toolJson('tool-1', connected: false)],
      );
      expect(
        find.text('Not connected'),
        findsOneWidget,
        reason: 'card trailing',
      );
      await tester.tap(find.text('Notion'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('oauth-status')),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Disconnect'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await settle(tester);
      expect(engine.called('POST', '/tool-registry/tool-1/authorize'), isTrue);
      expect(launched.single.toString(), 'https://idp.example/authorize?x=1');

      final Finder submit = find.widgetWithText(FilledButton, 'Submit');
      expect(submit, findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.enterText(
        find.widgetWithText(TextField, 'Paste the address or code'),
        'http://127.0.0.1:9/api/v1/oauth/callback?code=c&state=s',
      );
      await tester.pump();
      // The engine now reports the tool as connected.
      engine.tools = <Map<String, dynamic>>[
        _toolJson('tool-1', connected: true),
      ];
      await tester.tap(submit);
      await settle(tester);

      expect(
        jsonDecode(engine.last('POST', '/oauth/auth-9/complete').body),
        <String, dynamic>{
          'redirectUrl':
              'http://127.0.0.1:9/api/v1/oauth/callback?code=c&state=s',
        },
      );
      expect(settings.tools.single.oauthConnected, isTrue);
      expect(find.text('Connected'), findsWidgets);
      expect(submit, findsNothing, reason: 'paste area is gone once connected');
    });

    testWidgets('a rejected paste shows the engine error inline', (
      WidgetTester tester,
    ) async {
      final (_, _Engine engine, _) = await pump(
        tester,
        tools: <Map<String, dynamic>>[_toolJson('tool-1', connected: false)],
      );
      engine
        ..completeStatus = 400
        ..completeBody = <String, dynamic>{'error': 'state does not match'};
      await tester.tap(find.text('Notion'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await settle(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Paste the address or code'),
        'bad',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
      await settle(tester);
      expect(find.text('state does not match'), findsOneWidget);
      expect(
        jsonDecode(engine.last('POST', '/oauth/auth-9/complete').body),
        <String, dynamic>{'code': 'bad'},
      );
    });

    testWidgets(
      'Connect on an already connected tool refreshes without a paste box',
      (WidgetTester tester) async {
        final (_, _Engine engine, List<Uri> launched) = await pump(
          tester,
          tools: <Map<String, dynamic>>[_toolJson('tool-1', connected: false)],
        );
        engine.authorizeBody = <String, dynamic>{
          'authId': null,
          'url': null,
          'status': 'connected',
        };
        engine.tools = <Map<String, dynamic>>[
          _toolJson('tool-1', connected: true),
        ];
        await tester.tap(find.text('Notion'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
        await settle(tester);
        expect(launched, isEmpty);
        expect(find.widgetWithText(FilledButton, 'Submit'), findsNothing);
        expect(find.text('Connected'), findsWidgets);
      },
    );

    testWidgets('Disconnect asks first, then deletes the stored sign-in', (
      WidgetTester tester,
    ) async {
      final (
        DashboardSettingsController settings,
        _Engine engine,
        _,
      ) = await pump(
        tester,
        tools: <Map<String, dynamic>>[_toolJson('tool-1', connected: true)],
      );
      await tester.tap(find.text('Notion'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.called('DELETE', '/tool-registry/tool-1/oauth'), isFalse);

      await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Disconnect'),
        ),
      );
      await settle(tester);
      expect(engine.called('DELETE', '/tool-registry/tool-1/oauth'), isTrue);
      expect(settings.tools.single.oauthConnected, isFalse);
      expect(find.text('Not connected'), findsWidgets);
    });

    testWidgets('Test shows Sign-in required when the server needs auth', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        tools: <Map<String, dynamic>>[_toolJson('tool-1', connected: false)],
      );
      await tester.tap(find.text('Notion'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await settle(tester);
      expect(find.text('Sign-in required'), findsOneWidget);
    });

    testWidgets('OAuth with a non-web endpoint is refused locally', (
      WidgetTester tester,
    ) async {
      final (_, _Engine engine, _) = await pump(tester);
      await chooseOAuthForNewHttpTool(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Tool name'),
        'Notion',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'https://'),
        'ftp://x',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'OAuth needs an endpoint URL starting with http:// or https://.',
        ),
        findsOneWidget,
      );
      expect(engine.called('POST', '/tool-registry'), isFalse);
    });
  });
}
