import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';

Future<Never> _noEngine({Uri? explicitEndpoint, String? explicitToken}) async {
  throw StateError('no engine in this test');
}

void main() {
  test('chat-only window bounds are kept apart from the normal window', () {
    final DashboardController controller = DashboardController(_noEngine);
    addTearDown(controller.dispose);

    controller.updateWindowState(
      windowX: 100,
      windowY: 80,
      windowWidth: 1280,
      windowHeight: 720,
      windowMaximized: false,
    );
    expect(controller.hasChatWindowBounds, isFalse);

    controller.updateChatWindowState(x: 1500, y: 40, width: 420, height: 720);

    expect(controller.hasChatWindowBounds, isTrue);
    expect(controller.chatWindowX, 1500);
    expect(controller.chatWindowWidth, 420);
    expect(controller.windowX, 100);
    expect(controller.windowY, 80);
    expect(controller.windowWidth, 1280);
    expect(controller.windowHeight, 720);

    controller.updateWindowState(windowWidth: 1400);
    expect(controller.chatWindowWidth, 420);
  });

  test('unusable chat-only bounds are ignored', () {
    final DashboardController controller = DashboardController(_noEngine);
    addTearDown(controller.dispose);

    controller.updateChatWindowState(
      x: double.nan,
      y: 0,
      width: 420,
      height: 720,
    );
    controller.updateChatWindowState(x: 0, y: 0, width: 0, height: 720);

    expect(controller.hasChatWindowBounds, isFalse);
  });
}
