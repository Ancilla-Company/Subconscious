import 'package:flutter/material.dart';

import '../controller/dashboard_controller.dart';
import 'window_caption_widgets.dart';

Future<void> initializeDesktopWindow() async {}

/// Web title bar: same content as the desktop caption bar (logo, connection
/// status, panel toggles, workspace picker) without window buttons, because
/// the browser owns the window.
final class EngineCompositionBar extends StatelessWidget {
  const EngineCompositionBar({required this.controller, super.key});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[controller, controller.settings]),
    builder: (BuildContext context, Widget? child) {
      final ThemeData theme = Theme.of(context);
      return ColoredBox(
        color: theme.colorScheme.surface,
        child: SizedBox(
          height: kCaptionBarHeight,
          child: Row(
            children: <Widget>[
              Expanded(child: CaptionTitleContent(controller: controller)),
              PanelVisibilityControls(
                controller: controller,
                brightness: theme.brightness,
              ),
              ThreadWorkspaceCaptionPicker(
                controller: controller,
                brightness: theme.brightness,
              ),
            ],
          ),
        ),
      );
    },
  );
}
