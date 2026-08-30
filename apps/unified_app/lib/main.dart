import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import 'features/connection/engine_connection_resolver.dart';
import 'features/dashboard/controller/dashboard_controller.dart';
import 'features/dashboard/presentation/dashboard_page.dart';
import 'features/dashboard/presentation/window_composition_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDesktopWindow();
  const String rawUrl = String.fromEnvironment('SUBCONSCIOUS_ENGINE_URL');
  const String token = String.fromEnvironment('SUBCONSCIOUS_ENGINE_TOKEN');
  const bool preferDev = bool.fromEnvironment('SUBCONSCIOUS_ENGINE_DEV');
  final Uri? explicitEndpoint = Uri.tryParse(rawUrl);
  final DashboardController controller = DashboardController(
    () => resolveEngineRepository(
      explicitEndpoint: explicitEndpoint,
      explicitToken: token,
      preferDev: preferDev,
    ),
    initialWorkspaceUuid: const String.fromEnvironment(
      'SUBCONSCIOUS_WORKSPACE_UUID',
    ),
  );
  unawaited(controller.load());
  runApp(SubconsciousApp(dashboardController: controller));
}

final class SubconsciousApp extends StatelessWidget {
  const SubconsciousApp({required this.dashboardController, super.key});
  final DashboardController dashboardController;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: DashboardPage(controller: dashboardController),
    theme: AppTheme.light(),
    title: 'Subconscious',
  );
}
