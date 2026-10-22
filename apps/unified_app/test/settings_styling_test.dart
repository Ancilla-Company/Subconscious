import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/settings/presentation/settings_main_panel.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

/// The shared theme itself is covered in shared_ui_kit; this checks the
/// settings page actually builds its controls from the kit under the form
/// theme on every platform and brightness.
void main() {
  for (final Brightness brightness in Brightness.values) {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.windows,
      // Web reports its host platform, so these cover web as well.
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      testWidgets('settings controls use the kit form theme on '
          '${platform.name} (${brightness.name})', (
        WidgetTester tester,
      ) async {
        final DashboardController dashboard = DashboardController(_noEngine)
          ..connectionStatus = EngineConnectionStatus.disconnected;
        addTearDown(dashboard.dispose);
        final HiveRuntime session = HiveRuntime(
          account: ServerAccountClient(
            baseUri: Uri.parse('https://api.test'),
            tokenStore: MemoryRefreshTokenStore(),
            client: MockClient(
              (http.Request _) async => http.Response('{}', 401),
            ),
          ),
        );
        addTearDown(session.dispose);
        final AccountController account = AccountController(
          session: session,
          clientProvider: () => null,
        );
        addTearDown(account.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness, platform: platform),
            home: Scaffold(
              body: SettingsMainPanel(
                controller: dashboard.settings,
                dashboardController: dashboard,
                accountController: account,
              ),
            ),
          ),
        );
        final BuildContext context = tester.element(
          find.byType(AppDropdown).first,
        );
        final ThemeData form = Theme.of(context);
        final ThemeData base = Theme.of(tester.element(find.byType(Scaffold)));
        expect(find.byType(AppFieldLabel), findsWidgets);
        expect(form.visualDensity, VisualDensity.compact);
        expect(form.inputDecorationTheme.filled, isTrue);
        expect(
          form.inputDecorationTheme.fillColor,
          base.colorScheme.surfaceContainerLowest,
        );
        final OutlinedBorder? shape = form.filledButtonTheme.style?.shape
            ?.resolve(<WidgetState>{});
        expect(
          (shape! as RoundedRectangleBorder).borderRadius,
          const BorderRadius.all(Radius.circular(3)),
        );
      }, variant: TargetPlatformVariant.only(platform));
    }
  }
}
