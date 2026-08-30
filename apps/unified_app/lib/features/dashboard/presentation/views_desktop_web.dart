import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

import '../../chat/engine_llm_provider.dart';
import '../../chat/presentation/engine_chat_panel.dart';
import '../../context/presentation/context_panel.dart';
import '../controller/dashboard_controller.dart';
import 'dashboard_main_panel.dart';
import 'window_composition_bar.dart';

const Color _dividerColor = Color(0xFFE0E0E0);
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
  Widget build(BuildContext context) {
    final double availableWidth = MediaQuery.sizeOf(context).width;
    final double maximumContextPanelWidth =
        (availableWidth -
                _sidebarAndDividerWidth -
                (_resizeDividerWidth * 2) -
                _minimumChatPanelWidth -
                _minimumMainPanelWidth)
            .clamp(_minimumContextPanelWidth, _maximumContextPanelWidth)
            .toDouble();
    final double contextPanelWidth = _contextPanelWidth
        .clamp(_minimumContextPanelWidth, maximumContextPanelWidth)
        .toDouble();
    final double contextLayoutWidth = _isContextPanelVisible
        ? contextPanelWidth + _resizeDividerWidth
        : 0;
    final double maximumChatPanelWidth =
        (availableWidth -
                _sidebarAndDividerWidth -
                _resizeDividerWidth -
                contextLayoutWidth -
                _minimumMainPanelWidth)
            .clamp(_minimumChatPanelWidth, _maximumChatPanelWidth)
            .toDouble();
    final double chatPanelWidth = _chatPanelWidth
        .clamp(_minimumChatPanelWidth, maximumChatPanelWidth)
        .toDouble();

    return Scaffold(
      body: Column(
        children: <Widget>[
          EngineCompositionBar(controller: widget.controller),
          Expanded(
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: _dividerColor)),
              ),
              child: Row(
                children: <Widget>[
                  _Sidebar(
                    selectedPanel: _selectedPanel,
                    isContextPanelVisible: _isContextPanelVisible,
                    onContextPanelVisibilityToggle:
                        _toggleContextPanelVisibility,
                    onPanelSelected: _selectPanel,
                  ),
                  const SizedBox(
                    width: 1,
                    height: double.infinity,
                    child: ColoredBox(color: _dividerColor),
                  ),
                  Container(
                    width: chatPanelWidth,
                    color: Colors.white,
                    child: AnimatedBuilder(
                      animation: widget.controller,
                      builder: (BuildContext context, Widget? child) {
                        if (widget.controller.isLoading ||
                            widget.controller.isLoadingChat) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (widget.controller.chatError
                            case final Object error) {
                          return _Unavailable(error: error);
                        }
                        final EngineLlmProvider? provider =
                            widget.controller.chatProvider;
                        if (provider != null && widget.controller.isConnected) {
                          return EngineChatPanel(
                            key: ValueKey<String>(
                              provider.threadUuid ??
                                  provider.workspaceUuid ??
                                  'chat',
                            ),
                            provider: provider,
                            title: widget.controller.selectedThread?.title,
                          );
                        }
                        return _Unavailable(error: widget.controller.error);
                      },
                    ),
                  ),
                  _PanelResizeDivider(
                    onDragUpdate: (DragUpdateDetails details) {
                      setState(() {
                        _chatPanelWidth = (chatPanelWidth + details.delta.dx)
                            .clamp(
                              _minimumChatPanelWidth,
                              maximumChatPanelWidth,
                            )
                            .toDouble();
                      });
                    },
                  ),
                  Expanded(
                    child: DashboardMainPanel(controller: widget.controller),
                  ),
                  if (_isContextPanelVisible) ...<Widget>[
                    _PanelResizeDivider(
                      onDragUpdate: (DragUpdateDetails details) {
                        setState(() {
                          _contextPanelWidth =
                              (contextPanelWidth - details.delta.dx)
                                  .clamp(
                                    _minimumContextPanelWidth,
                                    maximumContextPanelWidth,
                                  )
                                  .toDouble();
                        });
                      },
                    ),
                    SizedBox(
                      width: contextPanelWidth,
                      child: ContextPanel(
                        screen: _selectedPanel,
                        controller: widget.controller,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _PanelResizeDivider extends StatelessWidget {
  const _PanelResizeDivider({required this.onDragUpdate});

  final GestureDragUpdateCallback onDragUpdate;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: onDragUpdate,
      child: const ColoredBox(
        color: Colors.white,
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
                child: ColoredBox(color: _dividerColor),
              ),
            ],
          ),
        ),
      ),
    ),
  );
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
    color: Colors.white,
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
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(4, 4, 4, 0),
    child: SizedBox(height: 1, child: ColoredBox(color: _dividerColor)),
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
