import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/dashboard/presentation/dashboard_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dashboard launches on native and narrow platform targets', (
    WidgetTester tester,
  ) async {
    final DashboardController controller = DashboardController(
      ({Uri? explicitEndpoint, String? explicitToken}) async => null,
    );
    final AccountController accountController = AccountController(
      session: HiveRuntime.shared,
      clientProvider: () => null,
    );
    addTearDown(controller.dispose);
    addTearDown(accountController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: DashboardPage(
          controller: controller,
          accountController: accountController,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
