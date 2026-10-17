import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';

final class _FakeSocket implements EngineSocket {
  bool connected = false;

  @override
  bool get isConnected => connected;

  @override
  Stream<WireFrame> get frames => Stream<WireFrame>.fromIterable(const <WireFrame>[]);

  @override
  Future<void> connect() async => connected = true;

  @override
  void registerUiTools() {}

  @override
  Future<void> close() async => connected = false;

  @override
  Future<void> dispose() async => connected = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

/// An engine whose `/settings` answers with [settingsStatus].
final class _FakeEngine {
  _FakeEngine({this.settingsStatus = 200});

  int settingsStatus;
  int settingsCalls = 0;

  EngineRepository repository() => EngineRepository(
    rest: RestEngineClient(
      baseUri: Uri.parse('http://127.0.0.1:50506/api/v1/'),
      token: 't',
      client: MockClient((http.Request request) async {
        if (request.url.path.endsWith('/health')) {
          return _json(<String, dynamic>{'status': 'ok'});
        }
        if (request.url.path.endsWith('/settings')) {
          settingsCalls++;
          if (settingsStatus != 200) {
            return _json(<String, dynamic>{'detail': 'nope'}, settingsStatus);
          }
        }
        return _json(<dynamic>[]);
      }),
    ),
    socket: _FakeSocket(),
  );
}

Future<void> _ticks(WidgetTester tester, int count) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(DashboardController.reconnectInterval);
    await tester.pump();
  }
}

void main() {
  testWidgets('background ticks while disconnected do not notify', (
    WidgetTester tester,
  ) async {
    int resolverCalls = 0;
    int startupCalls = 0;
    final DashboardController controller = DashboardController(
      ({Uri? explicitEndpoint, String? explicitToken}) async {
        resolverCalls++;
        return null;
      },
      engineStartup: () async => startupCalls++,
    );

    unawaited(controller.load());
    await tester.pump();
    await tester.pump();
    expect(controller.connectionStatus, EngineConnectionStatus.disconnected);

    int notifications = 0;
    final List<EngineConnectionStatus> seen = <EngineConnectionStatus>[];
    controller.addListener(() {
      notifications++;
      seen.add(controller.connectionStatus);
    });
    final int resolverCallsBefore = resolverCalls;

    await _ticks(tester, 10);

    expect(resolverCalls, greaterThan(resolverCallsBefore));
    expect(notifications, 0, reason: 'statuses seen: $seen');
    expect(controller.connectionStatus, EngineConnectionStatus.disconnected);
    expect(startupCalls, 1);
    controller.dispose();
    await tester.pump();
  });

  testWidgets('retryEngineStart starts the engine once more', (
    WidgetTester tester,
  ) async {
    int startupCalls = 0;
    final DashboardController controller = DashboardController(
      ({Uri? explicitEndpoint, String? explicitToken}) async => null,
      engineStartup: () async => startupCalls++,
    );

    unawaited(controller.load());
    await tester.pump();
    await _ticks(tester, 5);
    expect(startupCalls, 1);

    unawaited(controller.retryEngineStart());
    await tester.pump();
    await _ticks(tester, 5);

    expect(startupCalls, 2);
    expect(controller.connectionStatus, EngineConnectionStatus.disconnected);
    controller.dispose();
    await tester.pump();
  });

  testWidgets('a 401 on settings reports the token mismatch', (
    WidgetTester tester,
  ) async {
    final _FakeEngine engine = _FakeEngine(settingsStatus: 401);
    final DashboardController controller = DashboardController(
      ({Uri? explicitEndpoint, String? explicitToken}) async =>
          engine.repository(),
    );

    unawaited(controller.load());
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(controller.connectionStatus, EngineConnectionStatus.disconnected);
    expect(controller.error.toString(), contains('rejected this app'));
    expect(controller.error.toString(), contains('50506'));
    controller.dispose();
    await tester.pump();
  });

  testWidgets('a failing settings load is not retried on every tick', (
    WidgetTester tester,
  ) async {
    final _FakeEngine engine = _FakeEngine(settingsStatus: 500);
    final DashboardController controller = DashboardController(
      ({Uri? explicitEndpoint, String? explicitToken}) async =>
          engine.repository(),
    );

    unawaited(controller.load());
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(controller.connectionStatus, EngineConnectionStatus.connected);
    expect(controller.settings.generalError, isNotNull);
    final int callsAfterConnect = engine.settingsCalls;

    await _ticks(tester, 10);

    expect(engine.settingsCalls, callsAfterConnect);
    expect(controller.connectionStatus, EngineConnectionStatus.connected);
    controller.dispose();
    await tester.pump();
  });
}
