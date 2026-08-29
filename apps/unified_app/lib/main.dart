import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import 'features/dashboard/controller/dashboard_controller.dart';
import 'features/dashboard/presentation/dashboard_page.dart';

void main() {
  final DashboardController dashboardController = DashboardController(
    repository: const DashboardRepository(api: BootstrapDashboardApi()),
  );
  unawaited(dashboardController.load());
  runApp(SubconsciousApp(dashboardController: dashboardController));
}

final class SubconsciousApp extends StatelessWidget {
  const SubconsciousApp({required this.dashboardController, super.key});

  final DashboardController dashboardController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DashboardPage(controller: dashboardController),
      theme: AppTheme.light(),
      title: 'Subconscious',
    );
  }
}
