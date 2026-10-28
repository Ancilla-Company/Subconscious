import 'dart:async';
import 'dart:io' show Platform;

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/account/account_controller.dart';
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

    // The title bar has a flyout toggle, before the logo, that opens the
    // threads. (The desktop title bar is built on Windows only.)
    if (Platform.isWindows) {
      final Finder toggle = find.byTooltip('Threads');
      expect(toggle, findsOneWidget);
      final Finder logo = find.bySemanticsLabel('Subconscious logo');
      expect(
        tester.getTopLeft(toggle).dx,
        lessThan(tester.getTopLeft(logo.first).dx),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byType(AppFlyoutHeader), findsOneWidget);
      await tester.tapAt(const Offset(410, 400));
      await tester.pumpAndSettle();
      expect(find.byType(AppFlyoutHeader), findsNothing);
    }

    // And it can be left again. The desktop title bar has installed its own
    // window handler by now, which talks to the real window, so the call is not
    // awaited: the layout flips before the handler runs.
    unawaited(dashboard.setChatOnly(false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MobileDashboardView), findsOneWidget);
  });
}
