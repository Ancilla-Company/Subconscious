import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import 'features/dashboard/controller/dashboard_controller.dart';
import 'features/dashboard/presentation/dashboard_page.dart';
import 'features/dashboard/presentation/window_composition_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDesktopWindow();
  final EngineRepository? repository = _createRepository();
  final DashboardController controller = DashboardController(
    repository: repository,
    initialWorkspaceUuid: const String.fromEnvironment(
      'SUBCONSCIOUS_WORKSPACE_UUID',
    ),
  );
  unawaited(controller.load());
  runApp(SubconsciousApp(dashboardController: controller));
}

EngineRepository? _createRepository() {
  const String rawUrl = String.fromEnvironment('SUBCONSCIOUS_ENGINE_URL');
  const String token = String.fromEnvironment('SUBCONSCIOUS_ENGINE_TOKEN');
  final Uri? httpUri = Uri.tryParse(rawUrl);
  if (httpUri == null || httpUri.host.isEmpty || token.isEmpty) return null;
  final Uri wsUri = httpUri.replace(
    scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
    path: '/api/v1/events',
    queryParameters: <String, String>{'token': token},
  );
  return EngineRepository(
    rest: RestEngineClient(
      baseUri: httpUri.replace(path: '/api/v1/'),
      token: token,
    ),
    socket: WebSocketEngineClient(endpoint: wsUri),
  );
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
