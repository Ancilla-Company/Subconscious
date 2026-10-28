import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

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
(AppStatus, String) captionPresentation(
  EngineConnectionStatus status,
  HiveRuntime hive,
) {
  final (AppStatus, String) base = switch (status) {
    EngineConnectionStatus.connected => (AppStatus.connected, 'connected'),
    EngineConnectionStatus.connecting => (AppStatus.connecting, 'connecting'),
    EngineConnectionStatus.disconnected => (
      AppStatus.disconnected,
      'disconnected',
    ),
  };
  if (status == EngineConnectionStatus.connected) return base;
  if (hive.linkingLocalEngine) return (AppStatus.connecting, 'starting engine');
  if (!hive.hasLocalFullNode &&
      hive.isSignedIn &&
      engineCardViewFor(hive).isConnecting) {
    return (AppStatus.connecting, 'connecting');
  }
  return base;
}

/// Logo, app name and connection status. Shared by the native and web bars.
final class CaptionTitleContent extends StatelessWidget {
  const CaptionTitleContent({
    required this.controller,
    this.runtime,
    this.compact = false,
    super.key,
  });

  /// Logo and status only, for a very narrow title bar (the chat-only window).
  final bool compact;

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
    final (AppStatus, String) presentation = captionPresentation(
      controller.connectionStatus,
      hive,
    );
    return Row(
      children: <Widget>[
        SizedBox.square(
          dimension: compact ? 32 : 40,
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
        if (!compact) ...<Widget>[
          const SizedBox(width: 3),
          Text('Subconscious', style: theme.textTheme.labelLarge),
        ],
        const Spacer(),
        Transform.translate(
          offset: const Offset(0, 1),
          child: AppStatusDot(status: presentation.$1, label: presentation.$2),
        ),
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
    final Widget? chatOnlyButton = controller.supportsChatOnly
        ? _PanelVisibilityButton(
            brightness: brightness,
            visible: controller.chatOnly,
            visibleIcon: FluentIcons.chat_24_filled,
            hiddenIcon: FluentIcons.chat_24_regular,
            panelName: 'chat only',
            tooltip: controller.chatOnly
                ? 'Back to the full window'
                : 'Chat only, always on top',
            onPressed: () =>
                unawaited(controller.setChatOnly(!controller.chatOnly)),
          )
        : null;
    // In chat-only mode the other panels are hidden on purpose.
    if (controller.chatOnly) {
      return chatOnlyButton ?? const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ?chatOnlyButton,
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
    this.tooltip,
  });

  final String? tooltip;
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
      message: tooltip ?? '${visible ? 'Hide' : 'Show'} $panelName panel',
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
    final String label = controller.threadsWorkspace?.name ?? 'All workspaces';
    final String activeUuid = controller.threadsWorkspace?.uuid ?? '';
    // Same hover, focus and pressed feedback as the panel toggle buttons: the
    // caption bar is not a Material, so the trigger brings its own surface and
    // the popup button's ink takes these colours.
    final Color hoverColor = brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    return Material(
      color: Colors.transparent,
      child: Theme(
        data: Theme.of(context).copyWith(
          hoverColor: hoverColor,
          focusColor: hoverColor,
          highlightColor: hoverColor,
        ),
        child: _picker(context, label, activeUuid, foreground),
      ),
    );
  }

  Widget _picker(
    BuildContext context,
    String label,
    String activeUuid,
    Color foreground,
  ) {
    return AppPopupMenu<String>(
      tooltip: 'Active Workspace: $label',
      enabled: controller.isConnected && controller.workspaces.isNotEmpty,
      onSelected: (String uuid) {
        if (uuid.isEmpty) {
          unawaited(controller.selectThreadWorkspace(null));
          return;
        }
        for (final workspace in controller.workspaces) {
          if (workspace.uuid == uuid) {
            unawaited(controller.selectThreadWorkspace(workspace));
            return;
          }
        }
      },
      items: <AppMenuItem<String>>[
        AppMenuItem<String>(
          value: '',
          label: 'All workspaces',
          icon: FluentIcons.apps_20_regular,
          selected: activeUuid.isEmpty,
        ),
        for (final workspace in controller.workspaces)
          AppMenuItem<String>(
            value: workspace.uuid,
            label: workspace.name,
            icon: FluentIcons.folder_20_regular,
            selected: activeUuid == workspace.uuid,
          ),
      ],
      child: SizedBox(
        width: 180,
        height: kCaptionBarHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              Icon(FluentIcons.folder_20_regular, size: 16, color: foreground),
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
    );
  }
}

/// The title bar's button that opens the threads flyout in the chat-only
/// window, drawn like the panel toggles.
///
/// It sits beside the draggable title area, not inside it: a press in that
/// area starts a window drag, which would swallow the click.
final class CaptionFlyoutButton extends StatelessWidget {
  const CaptionFlyoutButton({
    required this.brightness,
    required this.onPressed,
    super.key,
  });

  static const String tooltip = 'Threads';
  static const IconData icon = FluentIcons.navigation_20_regular;

  final Brightness brightness;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Color foreground = brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final Color hover = brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            hoverColor: hover,
            focusColor: hover,
            highlightColor: hover,
            child: SizedBox(
              width: 42,
              height: kCaptionBarHeight,
              child: Icon(icon, size: 18, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}
