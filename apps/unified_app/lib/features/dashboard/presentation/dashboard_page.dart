import 'package:flutter/material.dart';

import '../controller/dashboard_controller.dart';
import 'views_desktop_web.dart';
import 'views_mobile.dart';

/// Routes one controller to platform-appropriate presentation structures.
final class DashboardPage extends StatelessWidget {
  const DashboardPage({required this.controller, super.key});

  static const double wideLayoutBreakpoint = 720;

  final DashboardController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < wideLayoutBreakpoint) {
          return MobileDashboardView(controller: controller);
        }
        return DesktopWebDashboardView(controller: controller);
      },
    );
  }
}
