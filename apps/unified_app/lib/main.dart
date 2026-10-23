import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import 'features/account/account_controller.dart';
import 'features/connection/engine_bootstrap.dart';
import 'features/connection/engine_connection_resolver.dart';
import 'features/connection/engine_launcher.dart';
import 'features/dashboard/controller/dashboard_controller.dart';
import 'features/dashboard/presentation/dashboard_page.dart';
import 'features/dashboard/presentation/window_composition_bar.dart';
import 'features/extension/extension_connection_resolver.dart';
import 'features/extension/extension_host.dart';
import 'features/extension/extension_runtime.dart';
import 'features/hive/hive_runtime.dart';
import 'features/settings/controller/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything reads the hive node identity: the popup and the side
  // panel(s) share one storage, so each open page claims its own slot.
  await ExtensionHost.instance.acquireInstanceSlot();
  httpLogSink = (String line) => debugPrint(line);
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
  // Production desktop builds start the packaged engine when none is
  // running. Development builds (SUBCONSCIOUS_ENGINE_DEV=true) never do.
  final EngineBootstrap? engineBootstrap = _hasLocalEngine
      ? EngineBootstrap(
          preferDev: preferDev,
          hasExplicitEndpoint: explicitEndpoint != null,
          engineLogPath: _engineLogPath(),
          isEngineHealthy: () async =>
              await discoverLocalEnginePort(preferDev: false) != null,
          launcher: PlatformEngineLauncher(
            executableOverride: const String.fromEnvironment(
              'SUBCONSCIOUS_ENGINE_EXE',
            ),
          ),
        )
      : null;
  final DashboardController controller = DashboardController(
    ({Uri? explicitEndpoint, String? explicitToken}) => resolveEngineRepository(
      explicitEndpoint: explicitEndpoint,
      explicitToken: explicitToken ?? token,
      preferDev: preferDev,
    ),
    initialEndpoint: explicitEndpoint,
    initialToken: token,
    engineStartup: engineBootstrap == null
        ? null
        : () async {
            await engineBootstrap.ensureRunning();
          },
    executors: HiveRuntime.shared,
    initialWorkspaceUuid: const String.fromEnvironment(
      'SUBCONSCIOUS_WORKSPACE_UUID',
    ),
  );
  final AccountController accountController = AccountController(
    // One server session is the source of truth for being signed in on every
    // platform. Devices with a local engine also sign that engine in; phones,
    // tablets and the web have none and reach a home engine over WebRTC.
    session: HiveRuntime.shared,
    clientProvider: () => controller.repository?.rest,
    thinClient: !_hasLocalEngine,
    // Inside the browser extension the account page can pair this browser
    // with a local engine.
    extensionPairing: ExtensionHost.instance.isExtension
        ? buildExtensionPairingController(
            onConnectionChanged: controller.reconnectNow,
          )
        : null,
    onEngineProfile: (String profileId) =>
        setActiveEngineProfile(preferDev: preferDev, profileId: profileId),
    onSessionChanged: () async {
      await controller.reconnectNow();
      if (!HiveRuntime.shared.hasLocalFullNode) return;
      // The engine lists itself on the account a moment after it is signed in.
      await HiveRuntime.shared.refresh();
      // 6 s, so this refresh is not swallowed by the engine's own 5 s
      // refresh throttle.
      unawaited(
        Future<void>.delayed(
          const Duration(seconds: 6),
          HiveRuntime.shared.refresh,
        ),
      );
    },
  );
  // A browser extension that was paired with an engine on this machine is a
  // client of that engine, like the desktop app: it registers no device of
  // its own until the engine had its chance.
  final bool pairedWithLocalEngine = await hasLoopbackPairing(
    ExtensionHost.instance,
  );
  HiveRuntime.shared.expectsLocalEngine =
      _hasLocalEngine || pairedWithLocalEngine;
  HiveRuntime.shared.probeLocalEngine = pairedWithLocalEngine
      ? () => pairedLocalEngineReachable(ExtensionHost.instance)
      : () async => await discoverLocalEnginePort(preferDev: preferDev) != null;
  HiveRuntime.shared.localEngineClient = () async =>
      controller.repository?.rest;
  HiveRuntime.shared.onEngineAvailable = controller.reconnectNow;
  // One source of truth: the dashboard controller decides if the engine is
  // connected; the hive runtime (card, device rows, Refresh) follows it.
  HiveRuntime.shared.engineSessionUp = () => controller.isConnected;
  controller.addListener(
    () => HiveRuntime.shared.engineSessionChanged(
      up: controller.isConnected,
      connecting:
          controller.connectionStatus == EngineConnectionStatus.connecting,
    ),
  );
  controller.onConnectionAttemptFailed = HiveRuntime.shared.engineAttemptFailed;
  unawaited(_loadEngineAndRestoreAccount(controller, accountController));
  runApp(
    SubconsciousApp(
      dashboardController: controller,
      accountController: accountController,
    ),
  );
}

/// Where the packaged engine writes its log, or null when unknown.
String? _engineLogPath() {
  final String? directory = engineDataDirectory(preferDev: false);
  if (directory == null) return null;
  final String separator = defaultTargetPlatform == TargetPlatform.windows
      ? r'\'
      : '/';
  return '$directory${separator}logs${separator}engine.log';
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

/// Whether this platform can run an engine next to the app.
bool get _hasLocalEngine =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };

Uri? _configuredEngineEndpoint({required bool preferDev}) {
  const String configuredUrl = String.fromEnvironment(
    'SUBCONSCIOUS_ENGINE_URL',
  );
  const String configuredPort = String.fromEnvironment(
    'SUBCONSCIOUS_ENGINE_PORT',
    defaultValue: '51515',
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
