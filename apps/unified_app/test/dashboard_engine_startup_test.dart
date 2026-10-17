import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/connection/engine_bootstrap.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a failed engine start is surfaced as the controller error', () async {
    const EngineStartException failure = EngineStartException(
      'The Subconscious engine did not start within 45 seconds.',
    );
    int calls = 0;
    final DashboardController controller = DashboardController(
      _noEngine,
      engineStartup: () async {
        calls++;
        throw failure;
      },
    );
    addTearDown(controller.dispose);

    await controller.load();

    expect(calls, 1);
    expect(controller.connectionStatus, EngineConnectionStatus.disconnected);
    expect(controller.error, same(failure));
  });

  test('without engineStartup the discovery error is reported', () async {
    final DashboardController controller = DashboardController(_noEngine);
    addTearDown(controller.dispose);

    await controller.load();

    expect(controller.connectionStatus, EngineConnectionStatus.disconnected);
    expect(controller.error, isA<StateError>());
  });

  test('a successful engine start leaves the discovery error alone', () async {
    final DashboardController controller = DashboardController(
      _noEngine,
      engineStartup: () async {},
    );
    addTearDown(controller.dispose);

    await controller.load();

    expect(controller.error, isA<StateError>());
  });
}
