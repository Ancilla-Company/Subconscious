import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screen_helpers.dart';

import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/dashboard/presentation/views_mobile.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  for (final Brightness brightness in Brightness.values) {
    testWidgets('mobile flyout is a single column (${brightness.name})', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(360, 800));
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
          theme: ThemeData(brightness: brightness),
          home: MobileDashboardView(
            controller: dashboard,
            accountController: account,
          ),
        ),
      );
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Workspaces'), findsWidgets);
      expect(find.text('Threads'), findsWidgets);
      expect(find.text('Files'), findsWidgets);
      expect(find.byType(FlyoutNavButton), findsNWidgets(4));
      expect(find.byType(SidebarButton), findsOneWidget);

      final Size settings = tester.getSize(find.byType(SidebarButton));
      expect(settings.width, settings.height);
      final Rect settingsRect = tester.getRect(find.byType(SidebarButton));
      final Rect accountRect = tester.getRect(
        find.byType(FlyoutNavButton).last,
      );
      final Rect drawerRect = tester.getRect(find.byType(Drawer));
      expect(accountRect.left, greaterThan(settingsRect.right));
      expect(accountRect.right, drawerRect.right - 8);

      final ColorScheme colors = Theme.of(tester.element(find.byType(Drawer)))
          .colorScheme;
      Color? fill(int index) => tester
          .widget<Material>(
            find
                .descendant(
                  of: find.byType(FlyoutNavButton).at(index),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color;
      // Threads is the default active section.
      expect(fill(1), colors.secondaryContainer);
      expect(fill(0), Colors.transparent);
    });
  }
}
