import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../hive/engine_card_view.dart';
import '../../hive/hive_runtime.dart';
import '../../settings/controller/settings_controller.dart';
import '../controller/dashboard_controller.dart';

/// Height of the custom title bar (matches the native caption height).
const double kCaptionBarHeight = 32;

/// Chip colour and text. While the engine card is (re)connecting, or the
/// local engine is still being linked, the chip is amber and never says
/// "disconnected" (AC-26).
@visibleForTesting
(Color, String) captionPresentation(
  EngineConnectionStatus status,
  HiveRuntime hive,
) {
  final (Color, String) base = switch (status) {
    EngineConnectionStatus.connected => (Colors.green, 'connected'),
    EngineConnectionStatus.connecting => (Colors.amber, 'connecting'),
    EngineConnectionStatus.disconnected => (Colors.red, 'disconnected'),
  };
  if (status == EngineConnectionStatus.connected) return base;
  if (hive.linkingLocalEngine) return (Colors.amber, 'starting engine');
  if (!hive.hasLocalFullNode &&
      hive.isSignedIn &&
      engineCardViewFor(hive).isConnecting) {
    return (Colors.amber, 'connecting');
  }
  return base;
}

/// Logo, app name and connection status. Shared by the native and web bars.
final class CaptionTitleContent extends StatelessWidget {
  const CaptionTitleContent({
    required this.controller,
    this.runtime,
    super.key,
  });

  final DashboardController controller;

  /// Source of the engine card state; defaults to [HiveRuntime.shared].
  final HiveRuntime? runtime;

  @override
  Widget build(BuildContext context) {
    final HiveRuntime hive = runtime ?? HiveRuntime.shared;
    return ListenableBuilder(
      listenable: hive,
      builder: (BuildContext context, Widget? child) => _content(context, hive),
    );
  }

  Widget _content(BuildContext context, HiveRuntime hive) {
    final ThemeData theme = Theme.of(context);
    final (Color, String) presentation = captionPresentation(
      controller.connectionStatus,
      hive,
    );
    return Row(
      children: <Widget>[
        SizedBox.square(
          dimension: 40,
          child: Center(
            child: SvgPicture.asset(
              'windows/runner/resources/icon_title.svg',
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(
                theme.colorScheme.onSurface,
                BlendMode.srcIn,
              ),
              semanticsLabel: 'Subconscious logo',
            ),
          ),
        ),
        const SizedBox(width: 3),
        Text('Subconscious', style: theme.textTheme.labelLarge),
        const Spacer(),
        Transform.translate(
          offset: const Offset(0, 2),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: presentation.$1,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(presentation.$2, style: theme.textTheme.labelMedium),
        const SizedBox(width: 12),
      ],
    );
  }
}
final class PanelVisibilityControls extends StatelessWidget {
  const PanelVisibilityControls({
    required this.controller,
    required this.brightness,
  });

  final DashboardController controller;
  final Brightness brightness;

  bool _isVisible(DashboardPanel panel) => switch (panel) {
    DashboardPanel.chat => controller.chatPanelVisible,
    DashboardPanel.main => controller.mainPanelVisible,
    DashboardPanel.context => controller.contextPanelVisible,
  };

  void _toggle(DashboardPanel panel) {
    final bool visible = _isVisible(panel);
    switch (panel) {
      case DashboardPanel.chat:
        controller.updateLayoutState(chatPanelVisible: !visible);
      case DashboardPanel.main:
        controller.updateLayoutState(mainPanelVisible: !visible);
      case DashboardPanel.context:
        controller.updateLayoutState(contextPanelVisible: !visible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<DashboardPanel> panels = controller.settings.panelOrder;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _PanelVisibilityButton(
          brightness: brightness,
          visible: _isVisible(panels[0]),
          visibleIcon: FluentIcons.panel_left_24_filled,
          hiddenIcon: FluentIcons.panel_left_24_regular,
          panelName: panels[0].name,
          onPressed: () => _toggle(panels[0]),
        ),
        _PanelVisibilityButton(
          brightness: brightness,
          visible: _isVisible(panels[1]),
          visibleIcon: FluentIcons.layout_column_three_focus_center_24_filled,
          hiddenIcon: FluentIcons.layout_column_three_24_regular,
          panelName: panels[1].name,
          onPressed: () => _toggle(panels[1]),
        ),
        _PanelVisibilityButton(
          brightness: brightness,
          visible: _isVisible(panels[2]),
          visibleIcon: FluentIcons.panel_right_24_filled,
          hiddenIcon: FluentIcons.panel_right_24_regular,
          panelName: panels[2].name,
          onPressed: () => _toggle(panels[2]),
        ),
      ],
    );
  }
}

final class _PanelVisibilityButton extends StatelessWidget {
  const _PanelVisibilityButton({
    required this.brightness,
    required this.visible,
    required this.visibleIcon,
    required this.hiddenIcon,
    required this.panelName,
    required this.onPressed,
  });

  final Brightness brightness;
  final bool visible;
  final IconData visibleIcon;
  final IconData hiddenIcon;
  final String panelName;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Color foreground = brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final Color hoverColor = brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    return Tooltip(
      message: '${visible ? 'Hide' : 'Show'} $panelName panel',
      child: Semantics(
        button: true,
        toggled: visible,
        label: '$panelName panel',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            hoverColor: hoverColor,
            focusColor: hoverColor,
            highlightColor: hoverColor,
            child: SizedBox(
              width: 42,
              height: kCaptionBarHeight,
              child: Icon(
                visible ? visibleIcon : hiddenIcon,
                size: 18,
                color: visible
                    ? foreground
                    : foreground.withValues(alpha: 0.55),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class ThreadWorkspaceCaptionPicker extends StatelessWidget {
  const ThreadWorkspaceCaptionPicker({
    required this.controller,
    required this.brightness,
  });

  final DashboardController controller;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final Color foreground = brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final Color hoverColor = brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    final String label = controller.threadsWorkspace?.name ?? 'All workspaces';
    return MenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(
          onPressed: controller.threadsWorkspace == null
              ? null
              : () => unawaited(controller.selectThreadWorkspace(null)),
          leadingIcon: const Icon(FluentIcons.apps_20_regular, size: 16),
          child: const Text('All workspaces'),
        ),
        for (final workspace in controller.workspaces)
          MenuItemButton(
            onPressed: controller.threadsWorkspace?.uuid == workspace.uuid
                ? null
                : () => unawaited(controller.selectThreadWorkspace(workspace)),
            leadingIcon: const Icon(FluentIcons.folder_20_regular, size: 16),
            child: Text(workspace.name),
          ),
      ],
      builder:
          (BuildContext context, MenuController menuController, Widget? child) {
            return Tooltip(
              message: 'Active Workspace: $label',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap:
                      controller.isConnected && controller.workspaces.isNotEmpty
                      ? menuController.open
                      : null,
                  hoverColor: hoverColor,
                  focusColor: hoverColor,
                  highlightColor: hoverColor,
                  child: SizedBox(
                    width: 180,
                    height: kCaptionBarHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            FluentIcons.folder_20_regular,
                            size: 16,
                            color: foreground,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(color: foreground),
                            ),
                          ),
                          Icon(
                            FluentIcons.chevron_down_16_regular,
                            size: 12,
                            color: foreground,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
    );
  }
}
