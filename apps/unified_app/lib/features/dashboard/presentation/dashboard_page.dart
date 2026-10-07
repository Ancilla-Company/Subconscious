import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../controller/dashboard_controller.dart';
import 'views_desktop_web.dart';
import 'views_mobile.dart';

/// Routes one controller to platform-appropriate presentation structures.
final class DashboardPage extends StatelessWidget {
  const DashboardPage({
    required this.controller,
    required this.accountController,
    super.key,
  });

  static const double wideLayoutBreakpoint = 720;

  final DashboardController controller;
  final AccountController accountController;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < wideLayoutBreakpoint) {
          return MobileDashboardView(
            controller: controller,
            accountController: accountController,
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
