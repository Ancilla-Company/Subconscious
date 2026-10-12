import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import 'features/account/account_controller.dart';
import 'features/connection/engine_connection_resolver.dart';
import 'features/dashboard/controller/dashboard_controller.dart';
import 'features/dashboard/presentation/dashboard_page.dart';
import 'features/dashboard/presentation/window_composition_bar.dart';
import 'features/settings/controller/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDesktopWindow();
  const String configuredToken = String.fromEnvironment(
    'SUBCONSCIOUS_ENGINE_TOKEN',
  );
  const bool preferDev = bool.fromEnvironment('SUBCONSCIOUS_ENGINE_DEV');
  final String token = configuredToken.isNotEmpty
      ? configuredToken
      : preferDev
      ? 'subconscious-dev-token'
      : '';
  final Uri? explicitEndpoint = _configuredEngineEndpoint(preferDev: preferDev);
  final DashboardController controller = DashboardController(
    ({Uri? explicitEndpoint, String? explicitToken}) => resolveEngineRepository(
      explicitEndpoint: explicitEndpoint,
      explicitToken: explicitToken ?? token,
      preferDev: preferDev,
    ),
    initialEndpoint: explicitEndpoint,
    initialToken: token,
    initialWorkspaceUuid: const String.fromEnvironment(
      'SUBCONSCIOUS_WORKSPACE_UUID',
    ),
  );
  final AccountController accountController = AccountController(
    clientProvider: () => controller.repository?.rest,
  );
  unawaited(_loadEngineAndRestoreAccount(controller, accountController));
  runApp(
    SubconsciousApp(
      dashboardController: controller,
      accountController: accountController,
    ),
  );
}

Future<void> _loadEngineAndRestoreAccount(
  DashboardController controller,
  AccountController accountController,
) async {
  try {
    await controller.load();
  } finally {
    await accountController.restoreSession();
  }
}

Uri? _configuredEngineEndpoint({required bool preferDev}) {
  const String configuredUrl = String.fromEnvironment(
    'SUBCONSCIOUS_ENGINE_URL',
  );
  const String configuredPort = String.fromEnvironment(
    'SUBCONSCIOUS_ENGINE_PORT',
    defaultValue: '55681',
  );
  final String defaultDevUrl =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? 'http://10.0.2.2'
      : 'http://localhost';
  final String endpointUrl = configuredUrl.trim().isNotEmpty
      ? configuredUrl.trim()
      : preferDev
      ? defaultDevUrl
      : '';
  if (endpointUrl.isEmpty) return null;
  final Uri? endpoint = Uri.tryParse(endpointUrl);
  final int? port = int.tryParse(configuredPort.trim());
  if (endpoint == null ||
      endpoint.host.isEmpty ||
      (endpoint.scheme != 'http' && endpoint.scheme != 'https') ||
      port == null ||
      port < 1 ||
      port > 65535) {
    return null;
  }
  return endpoint.replace(port: port);
}

final class SubconsciousApp extends StatelessWidget {
  const SubconsciousApp({
    required this.dashboardController,
    required this.accountController,
    super.key,
  });

  final DashboardController dashboardController;
  final AccountController accountController;

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
        ],
        home: DashboardPage(
          controller: dashboardController,
          accountController: accountController,
        ),
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
