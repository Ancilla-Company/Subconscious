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
import 'package:unified_app/features/dashboard/presentation/window_composition_bar.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  testWidgets(
    'the threads panel has its own picker only where the title bar has none',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
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
          home: DashboardPage(
            controller: dashboard,
            accountController: account,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(dashboard.chatOnly, isFalse);
      expect(find.byType(DesktopWebDashboardView), findsOneWidget);

      final Finder panelPicker = find.descendant(
        of: find.byType(ThreadsList),
        matching: find.byType(AppPickerButton<String>),
      );

      // Normal window: the title bar carries the picker (on Windows and the
      // web), so the panel has none.
      await tester.tap(find.byTooltip('Threads'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ThreadsList), findsOneWidget);
      expect(
        panelPicker,
        titleBarShowsWorkspacePicker(dashboard)
            ? findsNothing
            : findsOneWidget,
      );

      // Chat-only window: the title bar picker is hidden, so the panel shows
      // its own, beside the close button.
      dashboard.chatOnlyWindowHandler = (bool enabled) async {};
      await dashboard.setChatOnly(true);
      await tester.pump(const Duration(milliseconds: 300));
      expect(titleBarShowsWorkspacePicker(dashboard), isFalse);
      expect(panelPicker, findsOneWidget);
      expect(find.byTooltip('Close threads'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}