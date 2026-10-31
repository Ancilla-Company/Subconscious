import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/chat/presentation/threads_list.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/dashboard/presentation/dashboard_page.dart';
import 'package:unified_app/features/dashboard/presentation/views_desktop_web.dart';
import 'package:unified_app/features/dashboard/presentation/views_mobile.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  testWidgets('the narrow chat-only window keeps the desktop shell', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420 * 2, 720 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final DashboardController dashboard = DashboardController(_noEngine);
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
        theme: AppTheme.light(),
        home: DashboardPage(controller: dashboard, accountController: account),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // Normally a 420 dp window gets the phone layout.
    expect(find.byType(MobileDashboardView), findsOneWidget);

    dashboard.chatOnlyWindowHandler = (bool enabled) async {};
    await dashboard.setChatOnly(true);
    await tester.pump(const Duration(milliseconds: 300));

    // Chat-only is still a desktop window: desktop shell, no touch layout.
    expect(find.byType(DesktopWebDashboardView), findsOneWidget);
    expect(find.byType(MobileDashboardView), findsNothing);
    expect(tester.takeException(), isNull);

    // No flyout in the title bar any more: the chat's own header has the
    // threads button, and the list it opens carries the workspace picker (the
    // title bar has no room for it) beside a close button.
    expect(find.byTooltip('Threads'), findsOneWidget);
    expect(find.byType(AppFlyoutHeader), findsNothing);
    await tester.tap(find.byTooltip('Threads'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ThreadsList), findsOneWidget);
    expect(find.byType(AppPickerButton<String>), findsOneWidget);
    expect(find.byTooltip('Close threads'), findsWidgets);
    await tester.tap(find.byTooltip('Close threads').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ThreadsList), findsNothing);
    // And it can be left again. The desktop title bar has installed its own
    // window handler by now, which talks to the real window, so the call is not
    // awaited: the layout flips before the handler runs.
    unawaited(dashboard.setChatOnly(false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MobileDashboardView), findsOneWidget);
  });
}
