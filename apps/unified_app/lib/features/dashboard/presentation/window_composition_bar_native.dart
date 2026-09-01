import 'dart:async';
import 'dart:io';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:window_manager/window_manager.dart';

import '../controller/dashboard_controller.dart';

const MethodChannel _windowFrameChannel = MethodChannel(
  'company.ancilla.subconscious/window_frame',
);

Future<void> initializeDesktopWindow() async {
  if (!Platform.isWindows) return;
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      minimumSize: Size(800, 560),
      title: 'Subconscious',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
}

final class EngineCompositionBar extends StatefulWidget {
  const EngineCompositionBar({required this.controller, super.key});

  final DashboardController controller;

  @override
  State<EngineCompositionBar> createState() => _EngineCompositionBarState();
}

final class _EngineCompositionBarState extends State<EngineCompositionBar>
    with WindowListener {
  bool _isMaximized = false;
  bool _hasRestoredWindowState = false;
  bool _isRestoringWindowState = false;
  bool _isClosing = false;
  (int, int, Brightness)? _nativeFrameAppearance;

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows) return;
    windowManager.addListener(this);
    widget.controller.addListener(_onControllerChanged);
    _onControllerChanged();
  }

  @override
  void didUpdateWidget(covariant EngineCompositionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!Platform.isWindows || oldWidget.controller == widget.controller) {
      return;
    }
    oldWidget.controller.removeListener(_onControllerChanged);
    widget.controller.addListener(_onControllerChanged);
    _hasRestoredWindowState = false;
    _onControllerChanged();
  }

  void _onControllerChanged() {
    if (!widget.controller.hasLoadedNavigationState ||
        _hasRestoredWindowState ||
        _isRestoringWindowState) {
      return;
    }
    unawaited(_restoreWindowState());
  }

  Future<void> _restoreWindowState() async {
    _isRestoringWindowState = true;
    final bool captureInitialBounds = !widget.controller.hasWindowBounds;
    try {
      if (widget.controller.hasWindowBounds) {
        await windowManager.setBounds(
          Rect.fromLTWH(
            widget.controller.windowX!,
            widget.controller.windowY!,
            widget.controller.windowWidth!,
            widget.controller.windowHeight!,
          ),
        );
      }
      if (widget.controller.windowMaximized) {
        await windowManager.maximize();
      } else if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      }
      _isMaximized = await windowManager.isMaximized();
      _hasRestoredWindowState = true;
      if (mounted) setState(() {});
    } finally {
      _isRestoringWindowState = false;
    }
    if (captureInitialBounds) await _captureWindowState();
  }

  Future<void> _captureWindowState() async {
    if (!_hasRestoredWindowState || _isRestoringWindowState || _isClosing) {
      return;
    }
    final bool maximized = await windowManager.isMaximized();
    if (maximized) {
      widget.controller.updateWindowState(windowMaximized: true);
      return;
    }
    final Rect bounds = await windowManager.getBounds();
    widget.controller.updateWindowState(
      windowX: bounds.left,
      windowY: bounds.top,
      windowWidth: bounds.width,
      windowHeight: bounds.height,
      windowMaximized: false,
    );
  }

  Future<void> _closeWindow() async {
    if (_isClosing) return;
    await _captureWindowState();
    _isClosing = true;
    await widget.controller.flushAppState();
    await windowManager.destroy();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Platform.isWindows) return;
    final ThemeData theme = Theme.of(context);
    final (int, int, Brightness) appearance = (
      theme.colorScheme.outlineVariant.toARGB32(),
      theme.colorScheme.surface.toARGB32(),
      theme.brightness,
    );
    if (_nativeFrameAppearance == appearance) return;
    _nativeFrameAppearance = appearance;
    unawaited(
      _windowFrameChannel.invokeMethod<void>('setAppearance', <String, Object>{
        'borderColor': appearance.$1,
        'captionColor': appearance.$2,
        'dark': appearance.$3 == Brightness.dark,
      }),
    );
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      widget.controller.removeListener(_onControllerChanged);
    }
    super.dispose();
  }

  @override
  void onWindowMove() {
    unawaited(_captureWindowState());
  }

  @override
  void onWindowResize() {
    unawaited(_captureWindowState());
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
    if (_hasRestoredWindowState && !_isRestoringWindowState) {
      widget.controller.updateWindowState(windowMaximized: true);
    }
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
    unawaited(_captureWindowState());
  }

  @override
  void onWindowClose() {
    unawaited(_closeWindow());
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final ThemeData theme = Theme.of(context);
        final Brightness brightness = theme.brightness;
        final (Color, String) presentation = switch (widget
            .controller
            .connectionStatus) {
          EngineConnectionStatus.connected => (Colors.green, 'connected'),
          EngineConnectionStatus.connecting => (Colors.amber, 'connecting'),
          EngineConnectionStatus.disconnected => (Colors.red, 'disconnected'),
        };
        return ColoredBox(
          color: theme.colorScheme.surface,
          child: SizedBox(
            height: kWindowCaptionHeight,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: DragToMoveArea(
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 40,
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
                        Text(
                          'Subconscious',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const Spacer(),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: presentation.$1,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          presentation.$2,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        const SizedBox(width: 12),
                      ],
                    ),
                  ),
                ),
                _ThreadWorkspaceCaptionPicker(
                  controller: widget.controller,
                  brightness: brightness,
                ),
                WindowCaptionButton.minimize(
                  brightness: brightness,
                  onPressed: windowManager.minimize,
                ),
                if (_isMaximized)
                  WindowCaptionButton.unmaximize(
                    brightness: brightness,
                    onPressed: windowManager.unmaximize,
                  )
                else
                  WindowCaptionButton.maximize(
                    brightness: brightness,
                    onPressed: windowManager.maximize,
                  ),
                WindowCaptionButton.close(
                  brightness: brightness,
                  onPressed: windowManager.close,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _ThreadWorkspaceCaptionPicker extends StatelessWidget {
  const _ThreadWorkspaceCaptionPicker({
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
              message: 'Chat workspace: $label',
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
                    height: kWindowCaptionHeight,
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
