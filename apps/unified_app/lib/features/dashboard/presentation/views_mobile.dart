import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../../account/account_controller.dart';
import '../../chat/engine_llm_provider.dart';
import '../../account/presentation/account_panel.dart';
import '../../chat/presentation/engine_chat_panel.dart';
import '../../context/presentation/context_panel.dart';
import '../../hive/hive_runtime.dart';
import '../controller/dashboard_controller.dart';
import 'dashboard_main_panel.dart';

/// Minimum height and width of anything tappable on a touch screen.
const double _touchTarget = 48;

/// The kit's compact control size, used when a pointer drives the mobile
/// layout (the browser extension) so buttons match the desktop's 32 dp.
const double _compactTarget = 32;

final class MobileDashboardView extends StatelessWidget {
  const MobileDashboardView({
    required this.controller,
    required this.accountController,
    this.compactControls = false,
    super.key,
  });

  final DashboardController controller;
  final AccountController accountController;

  /// Uses the kit's 32 dp controls instead of 48 dp touch targets (a pointer
  /// drives the layout, as in the browser extension popup and side panel).
  final bool compactControls;

  double get _target => compactControls ? _compactTarget : _touchTarget;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[controller, accountController]),
    builder: (BuildContext context, Widget? child) => Theme(
      // The app bar, drawer and every panel share the form template, as on the
      // wide layout.
      data: appFormTheme(context),
      child: _scaffold(context),
    ),
  );

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      drawer: Drawer(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: SafeArea(
          child: _MobileFlyout(
            controller: controller,
            accountController: accountController,
            target: _target,
          ),
        ),
      ),
      appBar: AppBar(
        leadingWidth: _target + 8,
        leading: Builder(
          builder: (BuildContext context) => Align(
            child: AppIconButton(
              tooltip: 'Open navigation menu',
              onPressed: Scaffold.of(context).openDrawer,
              icon: FluentIcons.navigation_24_regular,
              size: compactControls
                  ? AppIconButtonSize.compact
                  : AppIconButtonSize.regular,
              minTouchTarget: _target,
              iconSize: compactControls ? 20 : 24,
            ),
          ),
        ),
        title: const Text('Subconscious'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: AppStatusDot(
              status: switch (controller.connectionStatus) {
                EngineConnectionStatus.connected => AppStatus.connected,
                EngineConnectionStatus.connecting => AppStatus.connecting,
                EngineConnectionStatus.disconnected => AppStatus.disconnected,
              },
            ),
          ),
        ],
      ),
      // Keeps the composer clear of the iOS home indicator and landscape
      // notch; Scaffold already shrinks the inset while the keyboard is up.
      body: SafeArea(top: false, child: _body()),
    );
  }

  Widget _body() {
    // The chat only has room under Threads on mobile, so show it while a tool
    // approval or tool sign-in is waiting, without changing the selected
    // section.
    if (controller.selectedSection != DashboardSection.threads &&
        controller.pendingToolApproval == null &&
        controller.pendingOAuth == null) {
      return DashboardMainPanel(
        controller: controller,
        accountController: accountController,
      );
    }
    final EngineLlmProvider? provider = controller.chatProvider;
    // No local engine on this device and nothing loaded yet: sign in directly
    // to the server. Once content has loaded it always stays visible.
    final HiveRuntime? server = accountController.serverRuntime;
    if (provider == null &&
        server != null &&
        !accountController.isAuthenticated &&
        !controller.isConnected &&
        !controller.isLoading) {
      return AccountPanel(controller: accountController);
    }
    // The composer is never hidden: while nothing is loaded (or loading
    // failed) the panel is shown with a disabled composer and the reason in a
    // popup above it.
    {
      final bool loading = controller.isLoading || controller.isLoadingChat;
      final bool hasProvider = provider != null;
      return EngineChatPanel(
        key: ValueKey<int>(controller.chatSessionVersion),
        provider: provider ?? controller.fallbackChatProvider,
        isComposerEnabled: hasProvider && controller.isConnected,
        errorMessage: loading && !hasProvider
            ? null
            : controller.chatError ??
                  (hasProvider
                      ? null
                      : controller.error ??
                            'Select a workspace to start chatting.'),
        borderlessComposer: true,
        minTouchTarget: _target,
        onOpenDevices: controller.openAccountShortcut,
        workspace: controller.threadsWorkspace,
        activeFile: controller.activeFileReference == null
            ? null
            : ChatFileReference(
                rootIndex: controller.activeFileReference!.rootIndex,
                path: controller.activeFileReference!.path,
              ),
        thread: controller.selectedThread,
        onCreateThread: controller.beginThreadDraft,
        onMaterializeThreadDraft: controller.materializeThreadDraft,
        onUpdateThreadDraft: controller.updateThreadDraft,
        onRefreshActiveFile: controller.refreshOpenFile,
        toolApproval: controller.pendingToolApproval,
        onToolApproval: (bool approved) =>
            unawaited(controller.respondToToolApproval(approved)),
        oauth: controller.pendingOAuth,
        onOAuthOpen: () => unawaited(controller.openOAuthSignIn()),
        onOAuthPaste: (String pasted) =>
            unawaited(controller.completeOAuthFromPaste(pasted)),
        onOAuthCancel: () => unawaited(controller.cancelOAuth()),
        oauthError: controller.oauthError == null
            ? null
            : describeChatError(controller.oauthError!),
        onUpdateThread:
            ({
              required ThreadInfo thread,
              String? title,
              String? defaultModelId,
              String? toolsConfig,
              required bool clearToolsConfig,
            }) => controller.updateThreadSettings(
              thread: thread,
              title: title,
              defaultModelId: defaultModelId,
              toolsConfig: toolsConfig,
              clearToolsConfig: clearToolsConfig,
            ),
        title: controller.selectedThread?.title ?? controller.pendingDraftTitle,
        draftToolsConfig: controller.pendingDraftToolsConfig,
        executors: controller.executors,
      );
    }
  }
}

final class _MobileFlyout extends StatelessWidget {
  const _MobileFlyout({
    required this.controller,
    required this.accountController,
    required this.target,
  });

  final DashboardController controller;
  final AccountController accountController;

  /// Height and width of the flyout's buttons and rows.
  final double target;

  void _selectSection(DashboardSection section) {
    unawaited(controller.activateSection(section));
  }

  void _selectAccount() {
    controller.openAccountShortcut();
  }

  Widget _menuButton({
    required IconData icon,
    required IconData selectedIcon,
    required String label,
    required DashboardSection section,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: FlyoutNavButton(
      icon: icon,
      selectedIcon: selectedIcon,
      label: label,
      height: target,
      selected: controller.selectedSection == section,
      onPressed: () => _selectSection(section),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Divider divider = Divider(
      height: 1,
      thickness: 1,
      color: colors.outlineVariant,
    );
    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: <Widget>[
          AppFlyoutHeader(
            title: 'Subconscious',
            logo: SvgPicture.asset(
              'windows/runner/resources/icon_title.svg',
              colorFilter: ColorFilter.mode(colors.onSurface, BlendMode.srcIn),
              semanticsLabel: 'Subconscious logo',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Column(
              children: <Widget>[
                _menuButton(
                  icon: FluentIcons.apps_24_regular,
                  selectedIcon: FluentIcons.apps_24_filled,
                  label: 'Workspaces',
                  section: DashboardSection.workspaces,
                ),
                _menuButton(
                  icon: FluentIcons.chat_24_regular,
                  selectedIcon: FluentIcons.chat_24_filled,
                  label: 'Threads',
                  section: DashboardSection.threads,
                ),
                _menuButton(
                  icon: FluentIcons.document_copy_24_regular,
                  selectedIcon: FluentIcons.document_copy_24_filled,
                  label: 'Files',
                  section: DashboardSection.files,
                ),
              ],
            ),
          ),
          divider,
          Expanded(
            child: ContextPanel(
              screen: controller.selectedSection,
              controller: controller,
              minTouchTarget: target,
              onSelection: () => Navigator.of(context).pop(),
            ),
          ),
          divider,
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: <Widget>[
                SidebarButton(
                  icon: FluentIcons.settings_24_regular,
                  selectedIcon: FluentIcons.settings_24_filled,
                  tooltip: 'Settings',
                  selected:
                      controller.selectedSection == DashboardSection.settings &&
                      !controller.accountShortcutSelected,
                  onPressed: () => _selectSection(DashboardSection.settings),
                  dimension: target,
                  borderRadius: 6,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AnimatedBuilder(
                    animation: accountController,
                    builder: (BuildContext context, Widget? child) =>
                        FlyoutNavButton(
                          icon: FluentIcons.person_24_regular,
                          selectedIcon: FluentIcons.person_24_filled,
                          label: accountController.sidebarTooltip,
                          height: target,
                          selected:
                              controller.selectedSection ==
                                  DashboardSection.settings &&
                              controller.accountShortcutSelected,
                          onPressed: _selectAccount,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
