import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../extension/extension_host.dart';
import '../controller/dashboard_controller.dart';
import 'views_desktop_web.dart';
import 'views_mobile.dart';

/// Routes one controller to platform-appropriate presentation structures.
final class DashboardPage extends StatelessWidget {
  const DashboardPage({
    required this.controller,
    required this.accountController,
    this.extensionHost,
    super.key,
  });

  /// Overrides [ExtensionHost.instance] (tests).
  final ExtensionHost? extensionHost;

  static const double wideLayoutBreakpoint = 720;

  final DashboardController controller;
  final AccountController accountController;

  @override
  Widget build(BuildContext context) {
    // The browser extension always uses the mobile shell (flyout drawer and a
    // full-height chat), whatever the popup or side panel width.
    final bool forceMobile =
        (extensionHost ?? ExtensionHost.instance).isExtension;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (forceMobile || constraints.maxWidth < wideLayoutBreakpoint) {
          return MobileDashboardView(
            controller: controller,
            accountController: accountController,
            // A pointer drives the extension: use the kit's 32 dp controls.
            compactControls: forceMobile,
          );
        }
        return DesktopWebDashboardView(
          controller: controller,
          accountController: accountController,
        );
      },
    );
  }
}
