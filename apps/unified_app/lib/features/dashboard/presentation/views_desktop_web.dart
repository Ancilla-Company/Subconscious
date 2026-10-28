import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
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
  static const double _resizeDividerWidth = AppPanelDivider.width;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

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
    const Widget sidebarDivider = AppVerticalRule();
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
          AppPanelDivider(
            onDragStart: (DragStartDetails details) => _beginResize(
              leftIndex: index - 1,
              rightIndex: index,
              flexiblePanelIndex: flexiblePanelIndex,
              panelOrder: panelOrder,
              pointerX: details.globalPosition.dx,
              chatPanelWidth: chatPanelWidth,
              contextPanelWidth: contextPanelWidth,
            ),
            onDragUpdate: (DragUpdateDetails details) => _updateResize(
              pointerX: details.globalPosition.dx,
              maximumChatPanelWidth: maximumChatPanelWidth,
              maximumContextPanelWidth: maximumContextPanelWidth,
            ),
            onDragEnd: (_) => _resize = null,
          ),
        _buildPanel(
          panelOrder[index],
          chatPanelWidth: chatPanelWidth,
          contextPanelWidth: contextPanelWidth,
          expandsToFill: index == flexiblePanelIndex,
        ),
      ],
    ];
    // Chat-only has no sidebar: the window is just the chat.
    final bool chatOnly = widget.controller.chatOnly;
    final bool sidebarOnRight =
        widget.controller.settings.sidebarPosition ==
        DashboardSidebarPosition.right;

    return Scaffold(
      key: _scaffoldKey,
      // Chat-only has no sidebar, so its threads live in a flyout opened from
      // the title bar.
      drawer: chatOnly
          ? Drawer(
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              child: _ChatOnlyFlyout(controller: widget.controller),
            )
          : null,
      body: Column(
        children: <Widget>[
          EngineCompositionBar(
            controller: widget.controller,
            onToggleFlyout: chatOnly
                ? () => _scaffoldKey.currentState?.openDrawer()
                : null,
          ),
          Expanded(
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                // The browser tab strip already separates the page from the
                // browser chrome, so the web header has no bottom rule.
                border: kIsWeb
                    ? null
                    : Border(top: BorderSide(color: colors.outlineVariant)),
              ),
              child: Row(
                children: <Widget>[
                  if (!sidebarOnRight && !chatOnly) ...<Widget>[
                    sidebar,
                    sidebarDivider,
                  ],
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
                  if (sidebarOnRight && !chatOnly) ...<Widget>[
                    sidebarDivider,
                    sidebar,
                  ],
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
          animation: Listenable.merge(<Listenable>[
            widget.controller,
            widget.accountController,
          ]),
          builder: (BuildContext context, Widget? child) {
            final EngineLlmProvider? provider = widget.controller.chatProvider;
            // The composer is never hidden: with nothing loaded (or a failed
            // load) the panel shows a disabled composer and the reason in a
            // popup above it.
            final bool loading =
                widget.controller.isLoading || widget.controller.isLoadingChat;
            {
              return EngineChatPanel(
                key: ValueKey<int>(widget.controller.chatSessionVersion),
                provider: provider ?? widget.controller.fallbackChatProvider,
                greetingName: widget.accountController.greetingName,
                // Read from the display, not the platform or window width.
                minTouchTarget: AppDensity.minTouchTarget(context),
                isComposerEnabled:
                    provider != null && widget.controller.isConnected,
                errorMessage: loading && provider == null
                    ? null
                    : widget.controller.chatError ??
                          (provider == null
                              ? widget.controller.error ??
                                    'Select a workspace to start chatting.'
                              : null),
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
                oauth: widget.controller.pendingOAuth,
                onOAuthOpen: () =>
                    unawaited(widget.controller.openOAuthSignIn()),
                onOAuthPaste: (String pasted) =>
                    unawaited(widget.controller.completeOAuthFromPaste(pasted)),
                onOAuthCancel: () => unawaited(widget.controller.cancelOAuth()),
                oauthError: widget.controller.oauthError == null
                    ? null
                    : describeChatError(widget.controller.oauthError!),
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
              );
            }
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
        minTouchTarget: AppDensity.minTouchTarget(context),
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

  /// The panel being resized by the current divider drag, with the pointer
  /// position and panel width when the drag began.
  _PanelResize? _resize;

  void _beginResize({
    required int leftIndex,
    required int rightIndex,
    required int flexiblePanelIndex,
    required List<DashboardPanel> panelOrder,
    required double pointerX,
    required double chatPanelWidth,
    required double contextPanelWidth,
  }) {
    final DashboardPanel panel = _panelForDivider(
      leftIndex: leftIndex,
      rightIndex: rightIndex,
      flexiblePanelIndex: flexiblePanelIndex,
      panelOrder: panelOrder,
    );
    if (panel == DashboardPanel.main) {
      _resize = null;
      return;
    }
    _resize = _PanelResize(
      panel: panel,
      isLeftPanel: panel == panelOrder[leftIndex],
      startPointerX: pointerX,
      startWidth: panel == DashboardPanel.chat
          ? chatPanelWidth
          : contextPanelWidth,
    );
  }

  /// Sets the width from the pointer's distance since the drag began, not
  /// from per-event deltas. Deltas are lost when several arrive before a
  /// rebuild and drift once a panel hits its limit; the pointer position keeps
  /// the divider under the cursor.
  void _updateResize({
    required double pointerX,
    required double maximumChatPanelWidth,
    required double maximumContextPanelWidth,
  }) {
    final _PanelResize? resize = _resize;
    if (resize == null) return;
    final double moved = pointerX - resize.startPointerX;
    final double width =
        resize.startWidth + (resize.isLeftPanel ? moved : -moved);
    switch (resize.panel) {
      case DashboardPanel.chat:
        widget.controller.updateLayoutState(
          chatPanelWidth: width
              .clamp(_minimumChatPanelWidth, maximumChatPanelWidth)
              .toDouble(),
        );
      case DashboardPanel.context:
        widget.controller.updateLayoutState(
          contextPanelWidth: width
              .clamp(_minimumContextPanelWidth, maximumContextPanelWidth)
              .toDouble(),
        );
      case DashboardPanel.main:
        break;
    }
  }
}

final class _PanelResize {
  const _PanelResize({
    required this.panel,
    required this.isLeftPanel,
    required this.startPointerX,
    required this.startWidth,
  });

  final DashboardPanel panel;
  final bool isLeftPanel;
  final double startPointerX;
  final double startWidth;
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
          const AppSidebarDivider(),
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

/// The threads flyout of the chat-only window: pick a workspace and a thread
/// without leaving the small chat window.
final class _ChatOnlyFlyout extends StatelessWidget {
  const _ChatOnlyFlyout({required this.controller});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // Elsewhere the threads list carries its own workspace picker; on Windows
    // that picker lives in the title bar, which the chat-only window has no
    // room for.
    final bool needsPicker =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    return AppFormTheme(
      child: ColoredBox(
        color: colors.surface,
        child: SafeArea(
          child: ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? child) => Column(
              children: <Widget>[
                AppFlyoutHeader(
                  title: 'Threads',
                  logo: SvgPicture.asset(
                    'windows/runner/resources/icon_title.svg',
                    colorFilter: ColorFilter.mode(
                      colors.onSurface,
                      BlendMode.srcIn,
                    ),
                    semanticsLabel: 'Subconscious logo',
                  ),
                ),
                if (needsPicker)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: AppDropdownField<String>(
                      value: controller.threadsWorkspace?.uuid ?? '',
                      items: <DropdownMenuItem<String>>[
                        const DropdownMenuItem<String>(
                          value: '',
                          child: Text(
                            'All workspaces',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        for (final Workspace workspace in controller.workspaces)
                          DropdownMenuItem<String>(
                            value: workspace.uuid,
                            child: Text(
                              workspace.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (String? uuid) {
                        Workspace? chosen;
                        for (final Workspace candidate
                            in controller.workspaces) {
                          if (candidate.uuid == uuid) chosen = candidate;
                        }
                        unawaited(controller.selectThreadWorkspace(chosen));
                      },
                    ),
                  ),
                Divider(height: 1, thickness: 1, color: colors.outlineVariant),
                Expanded(
                  child: ContextPanel(
                    screen: DashboardSection.threads,
                    controller: controller,
                    minTouchTarget: AppDensity.minTouchTarget(context),
                    onSelection: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
