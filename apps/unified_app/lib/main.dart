import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:shared_ui_kit/shared_ui_kit.dart';

import 'features/connection/engine_connection_resolver.dart';
import 'features/dashboard/controller/dashboard_controller.dart';
import 'features/dashboard/presentation/dashboard_page.dart';
import 'features/dashboard/presentation/window_composition_bar.dart';
import 'features/settings/controller/settings_controller.dart';

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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: dashboardController.settings,
    builder: (BuildContext context, Widget? child) {
      final AppAccentTheme accentTheme =
          dashboardController.settings.accentTheme;
      final Color accentColor = _accentColor(accentTheme);
      final bool monochrome = accentTheme == AppAccentTheme.neutral;
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          quill.FlutterQuillLocalizations.delegate,
        ],
        home: DashboardPage(controller: dashboardController),
        theme: AppTheme.light(seedColor: accentColor, monochrome: monochrome),
        darkTheme: AppTheme.dark(
          seedColor: accentColor,
          monochrome: monochrome,
        ),
        themeMode: switch (dashboardController.settings.lightingMode) {
          AppLightingMode.device => ThemeMode.system,
          AppLightingMode.light => ThemeMode.light,
          AppLightingMode.dark => ThemeMode.dark,
        },
        title: 'Subconscious',
      );
    },
  );
}

Color _accentColor(AppAccentTheme accent) => switch (accent) {
  AppAccentTheme.device => AppColors.seed,
  AppAccentTheme.neutral => Colors.black,
  AppAccentTheme.blue => const Color(0xFF0067C0),
  AppAccentTheme.purple => const Color(0xFF7C3AED),
  AppAccentTheme.green => const Color(0xFF107C10),
  AppAccentTheme.orange => const Color(0xFFCA5010),
  AppAccentTheme.red => const Color(0xFFD13438),
};
