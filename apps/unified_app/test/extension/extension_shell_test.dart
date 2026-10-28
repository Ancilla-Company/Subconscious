import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../screen_helpers.dart';

import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/dashboard/presentation/dashboard_page.dart';
import 'package:unified_app/features/dashboard/presentation/views_desktop_web.dart';
import 'package:unified_app/features/dashboard/presentation/views_mobile.dart';
import 'package:unified_app/features/extension/extension_pairing.dart';
import 'package:unified_app/features/extension/extension_pairing_controller.dart';
import 'package:unified_app/features/extension/presentation/extension_engine_section.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_extension_host.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  Future<void> pumpPage(
    WidgetTester tester, {
    required FakeExtensionHost host,
    required Size size,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final DashboardController dashboard = DashboardController(
      _noEngine,
      extensionHost: host,
    );
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
        theme: theme ?? AppTheme.light(),
        home: DashboardPage(
          controller: dashboard,
          accountController: account,
          extensionHost: host,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('extension controls use the kit 32 dp size, not 48 dp touch', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      host: FakeExtensionHost(),
      size: const Size(400, 560),
    );
    // The app bar menu button.
    expect(
      tester.getSize(find.byType(AppIconButton).first),
      const Size.square(32),
    );
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    final Finder navRows = find.byType(FlyoutNavButton);
    expect(navRows, findsWidgets);
    for (final Element row in navRows.evaluate()) {
      expect(row.size!.height, 32);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a small display gets 48 dp controls', (
    WidgetTester tester,
  ) async {
    useScreen(tester, const Size(400, 800), ratio: 2);
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
        home: MobileDashboardView(
          controller: dashboard,
          accountController: account,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.getSize(find.byType(AppIconButton).first),
      const Size.square(48),
    );
  });

  testWidgets('a narrow window on a large display keeps 32 dp controls', (
    WidgetTester tester,
  ) async {
    // A 400 dp wide window gets the phone structure, but the display it sits
    // on is a 1920x1080 monitor, so nothing about the controls grows.
    // pumpPage uses a pixel ratio of 2: 3840x2160 pixels is 1920x1080 dp.
    tester.view.display.size = const Size(3840, 2160);
    addTearDown(tester.view.display.reset);
    await pumpPage(
      tester,
      host: FakeExtensionHost(isExtension: false),
      size: const Size(400, 700),
    );
    expect(find.byType(MobileDashboardView), findsOneWidget);
    expect(
      tester.getSize(find.byType(AppIconButton).first),
      const Size.square(AppDensity.control),
    );
  });
  for (final (String, ThemeData) variant in <(String, ThemeData)>[
    ('light', AppTheme.light()),
    ('dark', AppTheme.dark()),
    ('neutral', AppTheme.light(monochrome: true)),
  ]) {
    testWidgets(
      'extension mode uses the mobile shell at 1280 wide (${variant.$1})',
      (WidgetTester tester) async {
        await pumpPage(
          tester,
          host: FakeExtensionHost(),
          size: const Size(1280, 800),
          theme: variant.$2,
        );
        expect(find.byType(MobileDashboardView), findsOneWidget);
        expect(find.byType(DesktopWebDashboardView), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'outside the extension a wide window still gets the desktop shell',
    (WidgetTester tester) async {
      await pumpPage(
        tester,
        host: FakeExtensionHost(isExtension: false),
        size: const Size(1280, 800),
      );
      expect(find.byType(DesktopWebDashboardView), findsOneWidget);
      expect(find.byType(MobileDashboardView), findsNothing);
    },
  );

  testWidgets('the Engine section shows pair, paired and no-engine states', (
    WidgetTester tester,
  ) async {
    final FakeExtensionHost host = FakeExtensionHost();
    bool engineUp = true;
    final ExtensionPairing pairing = ExtensionPairing(
      host: host,
      client: MockClient((http.Request r) async {
        if (!engineUp) throw http.ClientException('down');
        if (r.url.path == '/api/v1/pair') {
          return http.Response('{"token":"scp_t","client_id":"c"}', 200);
        }
        return http.Response('{"status":"ok","node_id":"n1"}', 200);
      }),
      requestAssertion: ({
        required String nodeId,
        required String clientNonce,
        required String origin,
      }) async => 'a',
    );
    final ExtensionPairingController controller = ExtensionPairingController(
      pairing: pairing,
      host: host,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Theme(
          data: AppTheme.light(),
          child: Scaffold(body: ExtensionEngineSection(controller: controller)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pair this browser'), findsOneWidget);
    await tester.tap(find.text('Pair this browser'));
    await tester.pumpAndSettle();
    expect(find.text('Unpair'), findsOneWidget);
    expect(host.connection?.engineToken, 'scp_t');
    engineUp = false;
    await tester.tap(find.text('Unpair'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No engine found'), findsOneWidget);
    expect(find.textContaining('Remote engines connect'), findsOneWidget);
    await tester.tap(find.text('Advanced: paste joining token'));
    await tester.pumpAndSettle();
    expect(find.byType(AppTextField), findsNWidgets(2));
  });
}
