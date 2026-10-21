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
import '../../settings/controller/settings_controller.dart';
import '../../settings/presentation/settings_main_panel.dart'
    show settingsFormTheme;
import '../controller/dashboard_controller.dart';
import 'dashboard_main_panel.dart';

final class MobileDashboardView extends StatelessWidget {
  const MobileDashboardView({
    required this.controller,
    required this.accountController,
    super.key,
  });

  final DashboardController controller;
  final AccountController accountController;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[controller, accountController]),
    builder: (BuildContext context, Widget? child) => Theme(
      // The app bar, drawer and every panel share the form template, as on the
      // wide layout.
      data: settingsFormTheme(context),
      child: _scaffold(context),
    ),
  );

  Widget _scaffold(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Scaffold(
      drawer: Drawer(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: SafeArea(
          child: _MobileFlyout(
            controller: controller,
            accountController: accountController,
          ),
        ),
      ),
      appBar: AppBar(
        // Flat and on the surface colour with a hairline, like the desktop top bar.
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: colors.outlineVariant)),
        leading: Builder(
          builder: (BuildContext context) => IconButton(
            tooltip: 'Open navigation menu',
            onPressed: Scaffold.of(context).openDrawer,
            icon: const Icon(FluentIcons.navigation_24_regular),
          ),
        ),
        title: const Text('Subconscious'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _MobileConnectionStatus(status: controller.connectionStatus),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    // The chat only has room under Threads on mobile, so show it while a tool
    // approval is waiting, without changing the selected section.
    if (controller.selectedSection != DashboardSection.threads &&
        controller.pendingToolApproval == null) {
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
    // The spinner only covers the initial load; loaded content is never
    // replaced by it.
    if (provider == null &&
        (controller.isLoading || controller.isLoadingChat)) {
      return const Center(child: CircularProgressIndicator());
    }
    final Object? chatError = controller.chatError;
    if (provider == null && chatError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('$chatError'),
        ),
      );
    }
    if (provider != null) {
      return EngineChatPanel(
        key: ValueKey<int>(controller.chatSessionVersion),
        provider: provider,
        isComposerEnabled: controller.isConnected,
        borderlessComposer: true,
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
        useNeutralUserBubbleForeground:
            controller.settings.accentTheme == AppAccentTheme.neutral,
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          controller.error?.toString() ??
              'Select a workspace to start chatting.',
        ),
      ),
    );
  }
}

final class _MobileFlyout extends StatelessWidget {
  const _MobileFlyout({
    required this.controller,
    required this.accountController,
  });

  final DashboardController controller;
  final AccountController accountController;

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
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  SvgPicture.asset(
                    'windows/runner/resources/icon_title.svg',
                    height: 24,
                    width: 24,
                    colorFilter: ColorFilter.mode(
                      colors.onSurface,
                      BlendMode.srcIn,
                    ),
                    semanticsLabel: 'Subconscious logo',
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Subconscious',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
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
                  dimension: 40,
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
                          height: 40,
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

final class _MobileConnectionStatus extends StatelessWidget {
  const _MobileConnectionStatus({required this.status});

  final EngineConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final (Color, String) presentation = switch (status) {
      EngineConnectionStatus.connected => (Colors.green, 'connected'),
      EngineConnectionStatus.connecting => (Colors.amber, 'connecting'),
      EngineConnectionStatus.disconnected => (Colors.red, 'disconnected'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: presentation.$1,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(presentation.$2, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}
