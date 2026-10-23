import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/extension/extension_host.dart';

import 'fake_extension_host.dart';

final class _Result {
  const _Result(this.turnId, this.requestId, this.ok, this.result, this.error);
  final String turnId;
  final String requestId;
  final bool ok;
  final Object? result;
  final String? error;
}

final class _FakeSocket implements EngineSocket {
  final StreamController<WireFrame> controller =
      StreamController<WireFrame>.broadcast(sync: true);
  bool connected = false;
  int uiRegistrations = 0;
  final List<List<ClientToolGroup>> registrations = <List<ClientToolGroup>>[];
  final List<_Result> results = <_Result>[];
  final List<(String, bool)> approvals = <(String, bool)>[];

  @override
  bool get isConnected => true;
  @override
  Stream<WireFrame> get frames => controller.stream;
  @override
  Future<void> connect() async => connected = true;
  @override
  void registerUiTools() => uiRegistrations++;
  @override
  void registerClientTools(List<ClientToolGroup> groups) =>
      registrations.add(groups);
  @override
  void sendClientToolResult({
    required String turnId,
    required String requestId,
    required bool ok,
    Object? result,
    String? error,
  }) => results.add(_Result(turnId, requestId, ok, result, error));
  @override
  void respondToolApproval({
    required String turnId,
    required String approvalId,
    required bool approved,
  }) => approvals.add((approvalId, approved));
  @override
  Future<void> close() async => connected = false;
  @override
  Future<void> dispose() async => connected = false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

WireFrame _toolRequest(
  String requestId,
  String group,
  String tool, [
  Map<String, dynamic> arguments = const <String, dynamic>{},
]) => WireFrame(
  type: 'client.tool.request',
  id: 'turn-1',
  data: <String, dynamic>{
    'request_id': requestId,
    'tool_name': tool,
    'group': group,
    'arguments': arguments,
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSocket socket;
  late FakeExtensionHost host;
  late DashboardController controller;

  Future<void> start(WidgetTester tester) async {
    controller = DashboardController(
      ({Uri? explicitEndpoint, String? explicitToken}) async =>
          EngineRepository(
            rest: RestEngineClient(
              baseUri: Uri.parse('http://127.0.0.1:51516/api/v1/'),
              token: 't',
              client: MockClient(
                (http.Request r) async => r.url.path.endsWith('/health')
                    ? _json(<String, dynamic>{'status': 'ok'})
                    : _json(<dynamic>[]),
              ),
            ),
            socket: socket,
          ),
      extensionHost: host,
    );
    unawaited(controller.load());
    await _settle(tester);
  }

  setUp(() {
    socket = _FakeSocket();
    host = FakeExtensionHost(groups: <ClientToolGroup>[browserGroup]);
  });

  testWidgets(
    'registers the UI tools and the extension groups after connecting',
    (WidgetTester tester) async {
      await start(tester);
      expect(controller.isConnected, isTrue, reason: '${controller.error}');
      expect(socket.uiRegistrations, 1);
      expect(socket.registrations, hasLength(1));
      expect(socket.registrations.single.single.group, 'browser');
      expect(host.visibility.first, isTrue);
      controller.dispose();
      expect(host.visibility.last, isFalse);
      expect(host.unsubscribed, 1);
      await tester.pump();
    },
  );

  testWidgets('outside the extension nothing is registered', (
    WidgetTester tester,
  ) async {
    host = FakeExtensionHost(
      isExtension: false,
      groups: <ClientToolGroup>[browserGroup],
    );
    await start(tester);
    expect(socket.uiRegistrations, 1);
    expect(socket.registrations, isEmpty);
    expect(host.listeners, isEmpty);
    controller.dispose();
    await tester.pump();
  });

  testWidgets(
    'a changed tool set is re-registered and removed groups are emptied',
    (WidgetTester tester) async {
      await start(tester);
      const ClientToolGroup page = ClientToolGroup(
        group: 'webmcp',
        title: 'Page tools',
        tools: <ClientToolDefinition>[
          ClientToolDefinition(
            id: 'search',
            description: 's',
            inputSchema: <String, dynamic>{'type': 'object'},
            operation: 'execute',
          ),
        ],
      );
      host.emitGroups(<ClientToolGroup>[browserGroup, page]);
      expect(
        socket.registrations.last.map((ClientToolGroup g) => g.group),
        <String>['browser', 'webmcp'],
      );
      // The page changed: the webmcp group is gone and must be emptied.
      host.emitGroups(<ClientToolGroup>[browserGroup]);
      final List<ClientToolGroup> last = socket.registrations.last;
      expect(last.map((ClientToolGroup g) => g.group), <String>[
        'browser',
        'webmcp',
      ]);
      expect(last.last.tools, isEmpty);
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'client.tool.request for an extension group round-trips through the host',
    (WidgetTester tester) async {
      await start(tester);
      socket.controller.add(
        _toolRequest('r1', 'browser', 'read_page', <String, dynamic>{
          'tab_id': 3,
        }),
      );
      await _settle(tester);
      expect(host.calls.single.$1, 'browser');
      expect(host.calls.single.$2, 'read_page');
      expect(jsonDecode(host.calls.single.$3), <String, dynamic>{'tab_id': 3});
      final _Result result = socket.results.single;
      expect(result.turnId, 'turn-1');
      expect(result.requestId, 'r1');
      expect(result.ok, isTrue);
      expect(result.result, <String, dynamic>{'tool': 'read_page'});
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('host failures and unknown groups or tools answer ok:false', (
    WidgetTester tester,
  ) async {
    host.onCall = (String g, String t, String a) async =>
        const ExtensionToolResult.failure('Tab closed');
    await start(tester);
    socket.controller
      ..add(_toolRequest('r1', 'browser', 'open_tab'))
      ..add(_toolRequest('r2', 'nope', 'read_page'))
      ..add(_toolRequest('r3', 'browser', 'drop_database'));
    await _settle(tester);
    expect(socket.results.map((_Result r) => r.ok), <bool>[
      false,
      false,
      false,
    ]);
    String? errorOf(String id) =>
        socket.results.firstWhere((_Result r) => r.requestId == id).error;
    expect(errorOf('r1'), 'Tab closed');
    expect(errorOf('r2'), contains('not available'));
    expect(errorOf('r3'), contains('drop_database'));
    expect(host.calls, hasLength(1), reason: 'only the registered tool ran');
    controller.dispose();
    await tester.pump();
  });

  testWidgets('a throwing host still answers', (WidgetTester tester) async {
    host.onCall = (String g, String t, String a) async =>
        throw StateError('boom');
    await start(tester);
    socket.controller.add(_toolRequest('r1', 'browser', 'read_page'));
    await _settle(tester);
    expect(socket.results.single.ok, isFalse);
    expect(socket.results.single.error, contains('boom'));
    controller.dispose();
    await tester.pump();
  });

  testWidgets('UI tool requests (no group) keep the explicit-approval rule', (
    WidgetTester tester,
  ) async {
    await start(tester);
    socket.controller.add(
      const WireFrame(
        type: 'client.tool.request',
        id: 'turn-1',
        data: <String, dynamic>{
          'request_id': 'ui1',
          'tool_name': 'navigate_ui',
          'arguments': <String, dynamic>{'destination': 'files'},
        },
      ),
    );
    await _settle(tester);
    expect(socket.results.single.ok, isFalse);
    expect(socket.results.single.error, contains('not explicitly approved'));
    expect(host.calls, isEmpty);
    controller.dispose();
    await tester.pump();
  });

  testWidgets(
    'approval requests for create and execute operations are queued',
    (WidgetTester tester) async {
      await start(tester);
      for (final String operation in <String>['create', 'execute']) {
        socket.controller.add(
          WireFrame(
            type: 'tool.approval.request',
            id: 'turn-1',
            data: <String, dynamic>{
              'approval_id': 'a-$operation',
              'thread_uuid': 't1',
              'tool_name': 'browser__open_tab',
              'operation': operation,
              'arguments': const <String, dynamic>{
                'url': 'https://example.com',
              },
            },
          ),
        );
      }
      await _settle(tester);
      expect(controller.pendingToolApproval?.operation, 'create');
      await controller.respondToToolApproval(true);
      expect(controller.pendingToolApproval?.operation, 'execute');
      expect(socket.approvals.single, ('a-create', true));
      // Extension tools run from the engine's own approval: no local grant is kept.
      socket.controller.add(_toolRequest('r1', 'browser', 'open_tab'));
      await _settle(tester);
      expect(socket.results.single.ok, isTrue);
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('hiding the app stops the host watcher', (
    WidgetTester tester,
  ) async {
    await start(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(host.visibility.last, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(host.visibility.last, isTrue);
    controller.dispose();
    await tester.pump();
  });
}
