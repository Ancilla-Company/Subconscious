import 'package:flutter/widgets.dart';

import '../controller/dashboard_controller.dart';

Future<void> initializeDesktopWindow() async {}

final class EngineCompositionBar extends StatelessWidget {
  const EngineCompositionBar({required this.controller, super.key});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
