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

  Future<void> pumpMobile(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
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
  }

  for (final Brightness brightness in Brightness.values) {
    group('mobile shell uses the kit (${brightness.name})', () {
      testWidgets('app bar has a 48 dp menu button and a status dot', (
        tester,
      ) async {
        await pumpMobile(tester, brightness: brightness);
        final Size menu = tester.getSize(
          find.ancestor(
            of: find.byTooltip('Open navigation menu'),
            matching: find.byType(AppIconButton),
          ),
        );
        expect(menu.width, greaterThanOrEqualTo(48));
        expect(menu.height, greaterThanOrEqualTo(48));
        expect(find.byType(AppStatusDot), findsOneWidget);
        // The engine is not reachable in this test: never green.
        final AppStatusDot dot = tester.widget<AppStatusDot>(
          find.byType(AppStatusDot),
        );
        expect(dot.status, isNot(AppStatus.connected));
      });

      testWidgets('flyout header, rows and footer are touch sized', (
        tester,
      ) async {
        await pumpMobile(tester, brightness: brightness);
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(AppFlyoutHeader), findsOneWidget);
        for (final Element e in find.byType(FlyoutNavButton).evaluate()) {
          expect(
            tester.getSize(find.byWidget(e.widget)).height,
            greaterThanOrEqualTo(48),
          );
        }
        expect(
          tester.getSize(find.byType(SidebarButton)).height,
          greaterThanOrEqualTo(48),
        );
      });

      testWidgets('context panel rows and header buttons are touch sized', (
        tester,
      ) async {
        await pumpMobile(tester, brightness: brightness);
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        expect(
          Scaffold.of(tester.element(find.byType(AppBar))).isDrawerOpen,
          isTrue,
        );
        // Workspaces section has the "New workspace" header button.
        await tester.tap(find.widgetWithText(FlyoutNavButton, 'Workspaces'));
        await tester.pumpAndSettle();
        final Finder add = find.byTooltip('New workspace');
        expect(add, findsOneWidget);
        expect(
          tester
              .getSize(
                find.ancestor(of: add, matching: find.byType(AppIconButton)),
              )
              .height,
          greaterThanOrEqualTo(44),
        );
      });
    });
  }
}
