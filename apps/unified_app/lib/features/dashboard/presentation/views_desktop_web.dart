import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

import '../../chat/engine_llm_provider.dart';
import '../../chat/presentation/engine_chat_panel.dart';
import '../../context/presentation/context_panel.dart';
import '../../settings/controller/settings_controller.dart';
import '../controller/dashboard_controller.dart';
import 'dashboard_main_panel.dart';
import 'window_composition_bar.dart';

typedef _ContextPanelScreen = ContextPanelScreen;

final class DesktopWebDashboardView extends StatefulWidget {
  const DesktopWebDashboardView({required this.controller, super.key});

  final DashboardController controller;

  @override
  State<DesktopWebDashboardView> createState() =>
      _DesktopWebDashboardViewState();
}

final class _DesktopWebDashboardViewState
    extends State<DesktopWebDashboardView> {
  static const double _defaultChatPanelWidth = 280;
  static const double _minimumChatPanelWidth = 140;
  static const double _maximumChatPanelWidth = 600;
  static const double _defaultContextPanelWidth = 280;
  static const double _minimumContextPanelWidth = 180;
  static const double _maximumContextPanelWidth = 600;
  static const double _minimumMainPanelWidth = 300;
  static const double _sidebarAndDividerWidth = 41;
  static const double _resizeDividerWidth = 5;

  _ContextPanelScreen _selectedPanel = _ContextPanelScreen.threads;
  bool _isContextPanelVisible = true;
  double _chatPanelWidth = _defaultChatPanelWidth;
  double _contextPanelWidth = _defaultContextPanelWidth;

  void _toggleContextPanelVisibility() {
    setState(() => _isContextPanelVisible = !_isContextPanelVisible);
  }

  void _selectPanel(_ContextPanelScreen panel) {
    setState(() {
      _selectedPanel = panel;
      _isContextPanelVisible = true;
    });
    switch (panel) {
      case ContextPanelScreen.files:
        widget.controller.settings.showFiles();
      case ContextPanelScreen.settings:
        widget.controller.settings.showSettings();
      case ContextPanelScreen.threads:
      case ContextPanelScreen.workspaces:
      case ContextPanelScreen.account:
        widget.controller.settings.showUtility();
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller.settings.addListener(_onSettingsChanged);
  }

  @override
  void didUpdateWidget(covariant DesktopWebDashboardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.settings.removeListener(_onSettingsChanged);
    widget.controller.settings.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double availableWidth = MediaQuery.sizeOf(context).width;
    final List<DashboardPanel> panelOrder = widget
        .controller
        .settings
        .panelOrder
        .where(
          (DashboardPanel panel) =>
              panel != DashboardPanel.context || _isContextPanelVisible,
        )
        .toList(growable: false);
    final double dividerLayoutWidth =
        _resizeDividerWidth * (panelOrder.length - 1);
    final double maximumContextPanelWidth =
        (availableWidth -
                _sidebarAndDividerWidth -
                dividerLayoutWidth -
                _minimumChatPanelWidth -
                _minimumMainPanelWidth)
            .clamp(_minimumContextPanelWidth, _maximumContextPanelWidth)
            .toDouble();
    final double contextPanelWidth = _contextPanelWidth
        .clamp(_minimumContextPanelWidth, maximumContextPanelWidth)
        .toDouble();
    final double maximumChatPanelWidth =
        (availableWidth -
                _sidebarAndDividerWidth -
                dividerLayoutWidth -
                (_isContextPanelVisible ? contextPanelWidth : 0) -
                _minimumMainPanelWidth)
            .clamp(_minimumChatPanelWidth, _maximumChatPanelWidth)
            .toDouble();
    final double chatPanelWidth = _chatPanelWidth
        .clamp(_minimumChatPanelWidth, maximumChatPanelWidth)
        .toDouble();
    final Widget sidebar = _Sidebar(
      selectedPanel: _selectedPanel,
      isContextPanelVisible: _isContextPanelVisible,
      onContextPanelVisibilityToggle: _toggleContextPanelVisibility,
      onPanelSelected: _selectPanel,
    );
    final Widget sidebarDivider = SizedBox(
      width: 1,
      height: double.infinity,
      child: ColoredBox(color: colors.outlineVariant),
    );
    final int mainPanelIndex = panelOrder.indexOf(DashboardPanel.main);
    final List<Widget> configuredPanels = <Widget>[
      for (int index = 0; index < panelOrder.length; index++) ...<Widget>[
        if (index > 0)
          _PanelResizeDivider(
            onDragUpdate: (DragUpdateDetails details) => _resizePanel(
              panel: _panelForDivider(
                leftIndex: index - 1,
                rightIndex: index,
                mainPanelIndex: mainPanelIndex,
                panelOrder: panelOrder,
              ),
              isLeftPanel:
                  _panelForDivider(
                    leftIndex: index - 1,
                    rightIndex: index,
                    mainPanelIndex: mainPanelIndex,
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
                  Expanded(child: Row(children: configuredPanels)),
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
  }) => switch (panel) {
    DashboardPanel.chat => SizedBox(
      key: const ValueKey<DashboardPanel>(DashboardPanel.chat),
      width: chatPanelWidth,
      child: ColoredBox(
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
            if (provider != null && widget.controller.isConnected) {
              return EngineChatPanel(
                key: ValueKey<String>(
                  provider.threadUuid ?? provider.workspaceUuid ?? 'chat',
                ),
                provider: provider,
                title: widget.controller.selectedThread?.title,
              );
            }
            return _Unavailable(error: widget.controller.error);
          },
        ),
      ),
    ),
    DashboardPanel.main => Expanded(
      key: const ValueKey<DashboardPanel>(DashboardPanel.main),
      child: DashboardMainPanel(controller: widget.controller),
    ),
    DashboardPanel.context => SizedBox(
      key: const ValueKey<DashboardPanel>(DashboardPanel.context),
      width: contextPanelWidth,
      child: ContextPanel(
        screen: _selectedPanel,
        controller: widget.controller,
      ),
    ),
  };

  DashboardPanel _panelForDivider({
    required int leftIndex,
    required int rightIndex,
    required int mainPanelIndex,
    required List<DashboardPanel> panelOrder,
  }) {
    final DashboardPanel left = panelOrder[leftIndex];
    final DashboardPanel right = panelOrder[rightIndex];
    if (left == DashboardPanel.main) return right;
    if (right == DashboardPanel.main) return left;
    return mainPanelIndex < leftIndex ? right : left;
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
    setState(() {
      switch (panel) {
        case DashboardPanel.chat:
          _chatPanelWidth = (chatPanelWidth + signedDelta)
              .clamp(_minimumChatPanelWidth, maximumChatPanelWidth)
              .toDouble();
        case DashboardPanel.context:
          _contextPanelWidth = (contextPanelWidth + signedDelta)
              .clamp(_minimumContextPanelWidth, maximumContextPanelWidth)
              .toDouble();
        case DashboardPanel.main:
          break;
      }
    });
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
    required this.isContextPanelVisible,
    required this.onContextPanelVisibilityToggle,
    required this.onPanelSelected,
  });

  final _ContextPanelScreen selectedPanel;
  final bool isContextPanelVisible;
  final VoidCallback onContextPanelVisibilityToggle;
  final ValueChanged<_ContextPanelScreen> onPanelSelected;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: SizedBox(
      width: 40,
      child: Column(
        children: <Widget>[
          _SidebarButton(
            icon: FluentIcons.panel_right_24_regular,
            selectedIcon: FluentIcons.panel_right_24_regular,
            tooltip: isContextPanelVisible
                ? 'Hide context panel'
                : 'Show context panel',
            onPressed: onContextPanelVisibilityToggle,
          ),
          _SidebarButton(
            icon: FluentIcons.apps_24_regular,
            selectedIcon: FluentIcons.apps_24_filled,
            tooltip: 'Workspaces',
            selected: selectedPanel == _ContextPanelScreen.workspaces,
            onPressed: () => onPanelSelected(_ContextPanelScreen.workspaces),
          ),
          _SidebarButton(
            icon: FluentIcons.chat_multiple_24_regular,
            selectedIcon: FluentIcons.chat_multiple_24_filled,
            tooltip: 'Threads',
            selected: selectedPanel == _ContextPanelScreen.threads,
            onPressed: () => onPanelSelected(_ContextPanelScreen.threads),
          ),
          _SidebarButton(
            icon: FluentIcons.folder_24_regular,
            selectedIcon: FluentIcons.folder_24_filled,
            tooltip: 'Files',
            selected: selectedPanel == _ContextPanelScreen.files,
            onPressed: () => onPanelSelected(_ContextPanelScreen.files),
          ),
          const Spacer(),
          const _SidebarDivider(),
          _SidebarButton(
            icon: FluentIcons.settings_24_regular,
            selectedIcon: FluentIcons.settings_24_filled,
            tooltip: 'Settings',
            selected: selectedPanel == _ContextPanelScreen.settings,
            onPressed: () => onPanelSelected(_ContextPanelScreen.settings),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _SidebarButton(
              icon: FluentIcons.person_circle_24_regular,
              selectedIcon: FluentIcons.person_circle_24_filled,
              tooltip: 'Account',
              selected: selectedPanel == _ContextPanelScreen.account,
              onPressed: () => onPanelSelected(_ContextPanelScreen.account),
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
    child: SizedBox(
      height: 1,
      child: ColoredBox(color: Theme.of(context).colorScheme.outlineVariant),
    ),
  );
}

final class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.icon,
    required this.selectedIcon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: IconButton(
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
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
