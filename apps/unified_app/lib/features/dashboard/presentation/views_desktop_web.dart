import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../../account/account_controller.dart';
import '../../chat/engine_llm_provider.dart';
import '../../chat/presentation/engine_chat_panel.dart';
import '../../context/presentation/context_panel.dart';
import '../../settings/controller/settings_controller.dart';
import '../controller/dashboard_controller.dart';
import 'dashboard_main_panel.dart';
import 'window_composition_bar.dart';

final class DesktopWebDashboardView extends StatefulWidget {
  const DesktopWebDashboardView({
    required this.controller,
    required this.accountController,
    super.key,
  });

  final DashboardController controller;
  final AccountController accountController;

  @override
  State<DesktopWebDashboardView> createState() =>
      _DesktopWebDashboardViewState();
}

final class _DesktopWebDashboardViewState
    extends State<DesktopWebDashboardView> {
  static const double _minimumChatPanelWidth = 140;
  static const double _maximumChatPanelWidth = 600;
  static const double _minimumContextPanelWidth = 180;
  static const double _maximumContextPanelWidth = 600;
  static const double _minimumMainPanelWidth = 300;
  static const double _sidebarAndDividerWidth = 41;
  static const double _resizeDividerWidth = 5;

  void _selectPanel(DashboardSection section) {
    widget.controller.updateLayoutState(contextPanelVisible: true);
    unawaited(widget.controller.activateSection(section));
  }

  void _selectAccount() {
    widget.controller.updateLayoutState(contextPanelVisible: true);
    widget.controller.openAccountShortcut();
  }

  @override
  void initState() {
    super.initState();
    widget.controller
      ..addListener(_onControllerChanged)
      ..settings.addListener(_onSettingsChanged);
  }

  @override
  void didUpdateWidget(covariant DesktopWebDashboardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller
      ..removeListener(_onControllerChanged)
      ..settings.removeListener(_onSettingsChanged);
    widget.controller
      ..addListener(_onControllerChanged)
      ..settings.addListener(_onSettingsChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller
      ..removeListener(_onControllerChanged)
      ..settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double availableWidth = MediaQuery.sizeOf(context).width;
    final bool isChatPanelVisible = widget.controller.chatPanelVisible;
    final bool isMainPanelVisible = widget.controller.mainPanelVisible;
    final bool isContextPanelVisible = widget.controller.contextPanelVisible;
    final List<DashboardPanel> configuredPanelOrder =
        widget.controller.settings.panelOrder;
    final Set<DashboardPanel> includedPanels = <DashboardPanel>{};
    final List<DashboardPanel> normalizedPanelOrder = <DashboardPanel>[
      for (final DashboardPanel panel in configuredPanelOrder)
        if (includedPanels.add(panel)) panel,
      for (final DashboardPanel panel in DashboardPanel.values)
        if (includedPanels.add(panel)) panel,
    ];
    final List<DashboardPanel> panelOrder = normalizedPanelOrder
        .where(
          (DashboardPanel panel) => switch (panel) {
            DashboardPanel.chat => isChatPanelVisible,
            DashboardPanel.main => isMainPanelVisible,
            DashboardPanel.context => isContextPanelVisible,
          },
        )
        .toList(growable: false);
    final String panelArrangementKey = panelOrder
        .map((DashboardPanel panel) => panel.name)
        .join(':');
    final double dividerLayoutWidth =
        _resizeDividerWidth * (panelOrder.isEmpty ? 0 : panelOrder.length - 1);
    final double maximumContextPanelWidth =
        (availableWidth -
                _sidebarAndDividerWidth -
                dividerLayoutWidth -
                (isChatPanelVisible ? _minimumChatPanelWidth : 0) -
                (isMainPanelVisible ? _minimumMainPanelWidth : 0))
            .clamp(_minimumContextPanelWidth, _maximumContextPanelWidth)
            .toDouble();
    final double contextPanelWidth = widget.controller.contextPanelWidth
        .clamp(_minimumContextPanelWidth, maximumContextPanelWidth)
        .toDouble();
    final double maximumChatPanelWidth =
        (availableWidth -
                _sidebarAndDividerWidth -
                dividerLayoutWidth -
                (isContextPanelVisible ? contextPanelWidth : 0) -
                (isMainPanelVisible ? _minimumMainPanelWidth : 0))
            .clamp(_minimumChatPanelWidth, _maximumChatPanelWidth)
            .toDouble();
    final double chatPanelWidth = widget.controller.chatPanelWidth
        .clamp(_minimumChatPanelWidth, maximumChatPanelWidth)
        .toDouble();
    final Widget sidebar = _Sidebar(
      selectedPanel: widget.controller.selectedSection,
      accountShortcutSelected: widget.controller.accountShortcutSelected,
      accountController: widget.accountController,
      onPanelSelected: _selectPanel,
      onAccountSelected: _selectAccount,
    );
    final Widget sidebarDivider = SizedBox(
      width: 1,
      height: double.infinity,
      child: ColoredBox(color: colors.outlineVariant),
    );
    final int mainPanelIndex = panelOrder.indexOf(DashboardPanel.main);
    final int chatPanelIndex = panelOrder.indexOf(DashboardPanel.chat);
    final int flexiblePanelIndex = mainPanelIndex >= 0
        ? mainPanelIndex
        : chatPanelIndex >= 0
        ? chatPanelIndex
        : panelOrder.isEmpty
        ? -1
        : 0;
    final List<Widget> configuredPanels = <Widget>[
      for (int index = 0; index < panelOrder.length; index++) ...<Widget>[
        if (index > 0)
          _PanelResizeDivider(
            onDragUpdate: (DragUpdateDetails details) => _resizePanel(
              panel: _panelForDivider(
                leftIndex: index - 1,
                rightIndex: index,
                flexiblePanelIndex: flexiblePanelIndex,
                panelOrder: panelOrder,
              ),
              isLeftPanel:
                  _panelForDivider(
                    leftIndex: index - 1,
                    rightIndex: index,
                    flexiblePanelIndex: flexiblePanelIndex,
                    panelOrder: panelOrder,
                  ) ==
                  panelOrder[index - 1],
              delta: details.delta.dx,
              chatPanelWidth: chatPanelWidth,
              maximumChatPanelWidth: maximumChatPanelWidth,
              contextPanelWidth: contextPanelWidth,
              maximumContextPanelWidth: maximumContextPanelWidth,
            ),
          ),
        _buildPanel(
          panelOrder[index],
          chatPanelWidth: chatPanelWidth,
          contextPanelWidth: contextPanelWidth,
          expandsToFill: index == flexiblePanelIndex,
        ),
      ],
    ];
    final bool sidebarOnRight =
        widget.controller.settings.sidebarPosition ==
        DashboardSidebarPosition.right;

    return Scaffold(
      body: Column(
        children: <Widget>[
          EngineCompositionBar(controller: widget.controller),
          Expanded(
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.outlineVariant)),
              ),
              child: Row(
                children: <Widget>[
                  if (!sidebarOnRight) ...<Widget>[sidebar, sidebarDivider],
                  Expanded(
                    child: panelOrder.isEmpty
                        ? Center(
                            child: SvgPicture.asset(
                              'windows/runner/resources/icon_title.svg',
                              width: 88,
                              height: 88,
                              colorFilter: ColorFilter.mode(
                                colors.onSurface,
                                BlendMode.srcIn,
                              ),
                              semanticsLabel: 'Subconscious logo',
                            ),
                          )
                        : Row(
                            key: ValueKey<String>(panelArrangementKey),
                            mainAxisAlignment: mainPanelIndex < 0
                                ? MainAxisAlignment.center
                                : MainAxisAlignment.start,
                            children: configuredPanels,
                          ),
                  ),
                  if (sidebarOnRight) ...<Widget>[sidebarDivider, sidebar],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(
    DashboardPanel panel, {
    required double chatPanelWidth,
    required double contextPanelWidth,
    required bool expandsToFill,
  }) {
    final Key key = ValueKey<DashboardPanel>(panel);
    final Widget child = switch (panel) {
      DashboardPanel.chat => ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: AnimatedBuilder(
          animation: widget.controller,
          builder: (BuildContext context, Widget? child) {
            if (widget.controller.isLoading ||
                widget.controller.isLoadingChat) {
              return const Center(child: CircularProgressIndicator());
            }
            if (widget.controller.chatError case final Object error) {
              return _Unavailable(error: error);
            }
            final EngineLlmProvider? provider = widget.controller.chatProvider;
            if (provider != null) {
              return EngineChatPanel(
                key: ValueKey<int>(widget.controller.chatSessionVersion),
                provider: provider,
                isComposerEnabled: widget.controller.isConnected,
                workspace: widget.controller.threadsWorkspace,
                activeFile: widget.controller.activeFileReference == null
                    ? null
                    : ChatFileReference(
                        rootIndex:
                            widget.controller.activeFileReference!.rootIndex,
                        path: widget.controller.activeFileReference!.path,
                      ),
                thread: widget.controller.selectedThread,
                onCreateThread: widget.controller.beginThreadDraft,
                onMaterializeThreadDraft:
                    widget.controller.materializeThreadDraft,
                onUpdateThreadDraft: widget.controller.updateThreadDraft,
                onRefreshActiveFile: widget.controller.refreshOpenFile,
                toolApproval: widget.controller.pendingToolApproval,
                onToolApproval: (bool approved) => unawaited(
                  widget.controller.respondToToolApproval(approved),
                ),
                onUpdateThread:
                    ({
                      required ThreadInfo thread,
                      String? title,
                      String? defaultModelId,
                      String? toolsConfig,
                      required bool clearToolsConfig,
                    }) => widget.controller.updateThreadSettings(
                      thread: thread,
                      title: title,
                      defaultModelId: defaultModelId,
                      toolsConfig: toolsConfig,
                      clearToolsConfig: clearToolsConfig,
                    ),
                title:
                    widget.controller.selectedThread?.title ??
                    widget.controller.pendingDraftTitle,
                draftToolsConfig: widget.controller.pendingDraftToolsConfig,
                executors: widget.controller.executors,
                useNeutralUserBubbleForeground:
                    widget.controller.settings.accentTheme ==
                    AppAccentTheme.neutral,
              );
            }
            return _Unavailable(error: widget.controller.error);
          },
        ),
      ),
      DashboardPanel.main => DashboardMainPanel(
        controller: widget.controller,
        accountController: widget.accountController,
      ),
      DashboardPanel.context => ContextPanel(
        screen: widget.controller.selectedSection,
        controller: widget.controller,
      ),
    };
    if (expandsToFill) return Expanded(key: key, child: child);
    return SizedBox(
      key: key,
      width: panel == DashboardPanel.chat ? chatPanelWidth : contextPanelWidth,
      child: child,
    );
  }

  DashboardPanel _panelForDivider({
    required int leftIndex,
    required int rightIndex,
    required int flexiblePanelIndex,
    required List<DashboardPanel> panelOrder,
  }) {
    final DashboardPanel left = panelOrder[leftIndex];
    final DashboardPanel right = panelOrder[rightIndex];
    if (leftIndex == flexiblePanelIndex) return right;
    if (rightIndex == flexiblePanelIndex) return left;
    return flexiblePanelIndex < leftIndex ? right : left;
  }

  void _resizePanel({
    required DashboardPanel panel,
    required bool isLeftPanel,
    required double delta,
    required double chatPanelWidth,
    required double maximumChatPanelWidth,
    required double contextPanelWidth,
    required double maximumContextPanelWidth,
  }) {
    final double signedDelta = isLeftPanel ? delta : -delta;
    switch (panel) {
      case DashboardPanel.chat:
        widget.controller.updateLayoutState(
          chatPanelWidth: (chatPanelWidth + signedDelta)
              .clamp(_minimumChatPanelWidth, maximumChatPanelWidth)
              .toDouble(),
        );
      case DashboardPanel.context:
        widget.controller.updateLayoutState(
          contextPanelWidth: (contextPanelWidth + signedDelta)
              .clamp(_minimumContextPanelWidth, maximumContextPanelWidth)
              .toDouble(),
        );
      case DashboardPanel.main:
        break;
    }
  }
}

final class _PanelResizeDivider extends StatelessWidget {
  const _PanelResizeDivider({required this.onDragUpdate});

  final GestureDragUpdateCallback onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: onDragUpdate,
        child: ColoredBox(
          color: colors.surface,
          child: SizedBox(
            width: 5,
            height: double.infinity,
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 2,
                  top: 0,
                  bottom: 0,
                  width: 1,
                  child: ColoredBox(color: colors.outlineVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selectedPanel,
    required this.accountShortcutSelected,
    required this.accountController,
    required this.onPanelSelected,
    required this.onAccountSelected,
  });

  final DashboardSection selectedPanel;
  final bool accountShortcutSelected;
  final AccountController accountController;
  final ValueChanged<DashboardSection> onPanelSelected;
  final VoidCallback onAccountSelected;

  static const EdgeInsets _buttonPadding = EdgeInsets.fromLTRB(4, 4, 4, 0);

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: SizedBox(
      width: 40,
      child: Column(
        children: <Widget>[
          SidebarButton(
            icon: FluentIcons.apps_24_regular,
            selectedIcon: FluentIcons.apps_24_filled,
            tooltip: 'Workspaces',
            outerPadding: _buttonPadding,
            selected: selectedPanel == DashboardSection.workspaces,
            onPressed: () => onPanelSelected(DashboardSection.workspaces),
          ),
          SidebarButton(
            icon: FluentIcons.chat_24_regular,
            selectedIcon: FluentIcons.chat_24_filled,
            tooltip: 'Threads',
            outerPadding: _buttonPadding,
            selected: selectedPanel == DashboardSection.threads,
            onPressed: () => onPanelSelected(DashboardSection.threads),
          ),
          SidebarButton(
            icon: FluentIcons.document_copy_24_regular,
            selectedIcon: FluentIcons.document_copy_24_filled,
            tooltip: 'Files',
            outerPadding: _buttonPadding,
            selected: selectedPanel == DashboardSection.files,
            onPressed: () => onPanelSelected(DashboardSection.files),
          ),
          const Spacer(),
          const _SidebarDivider(),
          SidebarButton(
            icon: FluentIcons.settings_24_regular,
            selectedIcon: FluentIcons.settings_24_filled,
            tooltip: 'Settings',
            outerPadding: _buttonPadding,
            selected:
                selectedPanel == DashboardSection.settings &&
                !accountShortcutSelected,
            onPressed: () => onPanelSelected(DashboardSection.settings),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: AnimatedBuilder(
              animation: accountController,
              builder: (BuildContext context, Widget? child) => SidebarButton(
                icon: FluentIcons.person_24_regular,
                selectedIcon: FluentIcons.person_24_filled,
                tooltip: accountController.sidebarTooltip,
                outerPadding: _buttonPadding,
                selected:
                    selectedPanel == DashboardSection.settings &&
                    accountShortcutSelected,
                onPressed: onAccountSelected,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

final class _SidebarDivider extends StatelessWidget {
  const _SidebarDivider();

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    indent: 4,
    endIndent: 4,
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}

final class _Unavailable extends StatelessWidget {
  const _Unavailable({this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(error?.toString() ?? 'Engine unavailable.'),
    ),
  );
}
