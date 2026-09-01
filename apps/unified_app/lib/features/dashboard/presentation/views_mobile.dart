import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../chat/engine_llm_provider.dart';
import '../../chat/presentation/engine_chat_panel.dart';
import '../../context/presentation/context_panel.dart';
import '../../settings/controller/settings_controller.dart';
import '../controller/dashboard_controller.dart';
import 'dashboard_main_panel.dart';

final class MobileDashboardView extends StatelessWidget {
  const MobileDashboardView({required this.controller, super.key});
  final DashboardController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (BuildContext context, Widget? child) => Scaffold(
      drawer: Drawer(
        child: SafeArea(child: _MobileFlyout(controller: controller)),
      ),
      appBar: AppBar(
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
    ),
  );

  Widget _body() {
    if (controller.selectedSection != DashboardSection.threads) {
      return DashboardMainPanel(controller: controller);
    }
    if (controller.isLoading || controller.isLoadingChat) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.chatError case final Object error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('$error'),
        ),
      );
    }
    final EngineLlmProvider? provider = controller.chatProvider;
    if (provider != null) {
      return EngineChatPanel(
        key: ValueKey<int>(controller.chatSessionVersion),
        provider: provider,
        isComposerEnabled: controller.isConnected,
        workspace: controller.threadsWorkspace,
        thread: controller.selectedThread,
        onCreateThread: controller.beginThreadDraft,
        onMaterializeThreadDraft: controller.materializeThreadDraft,
        onUpdateThreadDraft: controller.updateThreadDraft,
        onUpdateThread:
            ({
              required ThreadInfo thread,
              String? title,
              String? toolsConfig,
              required bool clearToolsConfig,
            }) => controller.updateThreadSettings(
              thread: thread,
              title: title,
              toolsConfig: toolsConfig,
              clearToolsConfig: clearToolsConfig,
            ),
        title: controller.selectedThread?.title ?? controller.pendingDraftTitle,
        draftToolsConfig: controller.pendingDraftToolsConfig,
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
  const _MobileFlyout({required this.controller});

  final DashboardController controller;

  void _selectSection(BuildContext context, DashboardSection section) {
    Navigator.of(context).pop();
    unawaited(controller.activateSection(section));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        ColoredBox(
          color: colors.surface,
          child: SizedBox(
            width: 48,
            child: Column(
              children: <Widget>[
                const SizedBox(height: 4),
                Tooltip(
                  message: 'Subconscious',
                  child: SizedBox.square(
                    dimension: 40,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: SvgPicture.asset(
                        'windows/runner/resources/icon_title.svg',
                        semanticsLabel: 'Subconscious logo',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                _MobileSidebarButton(
                  icon: FluentIcons.apps_24_regular,
                  selectedIcon: FluentIcons.apps_24_filled,
                  tooltip: 'Workspaces',
                  selected:
                      controller.selectedSection == DashboardSection.workspaces,
                  onPressed: () =>
                      _selectSection(context, DashboardSection.workspaces),
                ),
                _MobileSidebarButton(
                  icon: FluentIcons.chat_24_regular,
                  selectedIcon: FluentIcons.chat_24_filled,
                  tooltip: 'Threads',
                  selected:
                      controller.selectedSection == DashboardSection.threads,
                  onPressed: () =>
                      _selectSection(context, DashboardSection.threads),
                ),
                _MobileSidebarButton(
                  icon: FluentIcons.document_copy_24_regular,
                  selectedIcon: FluentIcons.document_copy_24_filled,
                  tooltip: 'Files',
                  selected:
                      controller.selectedSection == DashboardSection.files,
                  onPressed: () =>
                      _selectSection(context, DashboardSection.files),
                ),
                const Spacer(),
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 4,
                  endIndent: 4,
                  color: colors.outlineVariant,
                ),
                _MobileSidebarButton(
                  icon: FluentIcons.settings_24_regular,
                  selectedIcon: FluentIcons.settings_24_filled,
                  tooltip: 'Settings',
                  selected:
                      controller.selectedSection == DashboardSection.settings,
                  onPressed: () =>
                      _selectSection(context, DashboardSection.settings),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _MobileSidebarButton(
                    icon: FluentIcons.person_24_regular,
                    selectedIcon: FluentIcons.person_24_filled,
                    tooltip: 'Account',
                    selected:
                        controller.selectedSection == DashboardSection.account,
                    onPressed: () =>
                        _selectSection(context, DashboardSection.account),
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(width: 1, child: ColoredBox(color: colors.outlineVariant)),
        Expanded(
          child: Column(
            children: <Widget>[
              const SizedBox(
                height: 48,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Subconscious'),
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: colors.outlineVariant),
              Expanded(
                child: ContextPanel(
                  screen: controller.selectedSection,
                  controller: controller,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _MobileSidebarButton extends StatelessWidget {
  const _MobileSidebarButton({
    required this.icon,
    required this.selectedIcon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 40,
      child: IconButton(
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        isSelected: selected,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        selectedIcon: Icon(selectedIcon, size: 20),
        style: IconButton.styleFrom(
          backgroundColor: selected ? colors.secondaryContainer : null,
          foregroundColor: selected ? colors.onSecondaryContainer : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        tooltip: tooltip,
        icon: Icon(icon, size: 20),
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
