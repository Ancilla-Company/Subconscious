import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
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

void main() {
  testWidgets('engine down shows one banner, keeps theme changes, no spinner', (
    WidgetTester tester,
  ) async {
    final DashboardController dashboard = DashboardController(_noEngine)
      ..connectionStatus = EngineConnectionStatus.disconnected;
    addTearDown(dashboard.dispose);
    final AccountController account = AccountController(
      clientProvider: () => null,
    );
    addTearDown(account.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsMainPanel(
            controller: dashboard.settings,
            dashboardController: dashboard,
            accountController: account,
          ),
        ),
      ),
    );

    expect(find.text('Engine not connected.'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);

    await dashboard.settings.updateGeneralSetting(
      DashboardSettingsController.modeKey,
      'Dark',
    );
    await tester.pump();

    expect(dashboard.settings.lightingMode, AppLightingMode.dark);
    expect(dashboard.settings.hasPendingGeneral, isTrue);
    expect(dashboard.settings.generalError, isNull);
    expect(find.textContaining('will be saved when the engine'), findsOneWidget);
    expect(find.text('Engine not connected.'), findsOneWidget);

    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Engine not connected.'), findsOneWidget);
    }
  });

  test('pending changes are sent once when the engine is back', () async {
    final List<Map<String, dynamic>> puts = <Map<String, dynamic>>[];
    final EngineRepository repository = EngineRepository(
      rest: RestEngineClient(
        baseUri: Uri.parse('http://127.0.0.1:50506/api/v1/'),
        token: 't',
        client: MockClient((http.Request request) async {
          final Object? body = request.method == 'PUT'
              ? jsonDecode(request.body)
              : null;
          if (request.method == 'PUT') {
            puts.add(<String, dynamic>{'body': body});
          }
          return http.Response(
            request.method == 'PUT' ? jsonEncode(body) : '[]',
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
      socket: _FakeSocket(),
    );
    EngineRepository? current;
    final DashboardSettingsController settings = DashboardSettingsController(
      repositoryProvider: () => current,
    );
    addTearDown(settings.dispose);

    await settings.updateGeneralSetting(
      DashboardSettingsController.modeKey,
      'Dark',
    );
    expect(puts, isEmpty);
    expect(settings.hasPendingGeneral, isTrue);

    current = repository;
    await settings.loadGeneralSettings(force: true);

    expect(puts, hasLength(1));
    expect(settings.hasPendingGeneral, isFalse);
    expect(settings.lightingMode, AppLightingMode.dark);

    await settings.loadGeneralSettings(force: true);
    expect(puts, hasLength(1));
  });
}
