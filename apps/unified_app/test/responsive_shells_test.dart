import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/dashboard/presentation/views_desktop_web.dart';
import 'package:unified_app/features/dashboard/presentation/views_mobile.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

/// A theme variant the shells must lay out in without overflow.
typedef _Variant = ({String name, ThemeData theme});

final List<_Variant> _variants = <_Variant>[
  (name: 'light', theme: AppTheme.light()),
  (name: 'dark', theme: AppTheme.dark()),
  (name: 'neutral light', theme: AppTheme.light(monochrome: true)),
  (name: 'neutral dark', theme: AppTheme.dark(monochrome: true)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  Future<void> pumpShell(
    WidgetTester tester, {
    required Size size,
    required ThemeData theme,
    required Widget Function(
      DashboardController dashboard,
      AccountController account,
    )
    shell,
  }) async {
    tester.view.physicalSize = size * 2;
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
      MaterialApp(theme: theme, home: shell(dashboard, account)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final _Variant variant in _variants) {
    group('responsive shells (${variant.name})', () {
      testWidgets('mobile shell at 360x800 does not overflow', (tester) async {
        await pumpShell(
          tester,
          size: const Size(360, 800),
          theme: variant.theme,
          shell: (DashboardController d, AccountController a) =>
              MobileDashboardView(controller: d, accountController: a),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(AppIconButton), findsWidgets);
      });

      testWidgets('mobile shell at tablet width 800x1024 does not overflow', (
        tester,
      ) async {
        await pumpShell(
          tester,
          size: const Size(800, 1024),
          theme: variant.theme,
          shell: (DashboardController d, AccountController a) =>
              MobileDashboardView(controller: d, accountController: a),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('desktop shell at 1280x800 does not overflow', (
        tester,
      ) async {
        await pumpShell(
          tester,
          size: const Size(1280, 800),
          theme: variant.theme,
          shell: (DashboardController d, AccountController a) =>
              DesktopWebDashboardView(controller: d, accountController: a),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(SidebarButton), findsNWidgets(5));
        expect(find.byType(AppVerticalRule), findsOneWidget);
      });

      testWidgets('desktop shell at a narrow 900x600 does not overflow', (
        tester,
      ) async {
        await pumpShell(
          tester,
          size: const Size(900, 600),
          theme: variant.theme,
          shell: (DashboardController d, AccountController a) =>
              DesktopWebDashboardView(controller: d, accountController: a),
        );
        expect(tester.takeException(), isNull);
      });
    });
  }
}
