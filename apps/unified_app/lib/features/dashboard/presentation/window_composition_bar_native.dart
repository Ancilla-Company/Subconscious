import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../controller/dashboard_controller.dart';

Future<void> initializeDesktopWindow() async {
  if (!Platform.isWindows) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      backgroundColor: Colors.white,
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

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows) return;
    windowManager.addListener(this);
    _refreshMaximizedState();
  }

  Future<void> _refreshMaximizedState() async {
    final bool maximized = await windowManager.isMaximized();
    if (mounted && maximized != _isMaximized) {
      setState(() => _isMaximized = maximized);
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final (Color, String) presentation = switch (widget
            .controller
            .connectionStatus) {
          EngineConnectionStatus.connected => (Colors.green, 'connected'),
          EngineConnectionStatus.connecting => (Colors.amber, 'connecting'),
          EngineConnectionStatus.disconnected => (Colors.red, 'disconnected'),
        };
        return ColoredBox(
          color: Colors.white,
          child: SizedBox(
            height: kWindowCaptionHeight,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: DragToMoveArea(
                    child: Row(
                      children: <Widget>[
                        const SizedBox(width: 10),
                        const Icon(Icons.bolt, size: 16),
                        const SizedBox(width: 7),
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
                WindowCaptionButton.minimize(
                  brightness: Brightness.light,
                  onPressed: windowManager.minimize,
                ),
                if (_isMaximized)
                  WindowCaptionButton.unmaximize(
                    brightness: Brightness.light,
                    onPressed: windowManager.unmaximize,
                  )
                else
                  WindowCaptionButton.maximize(
                    brightness: Brightness.light,
                    onPressed: windowManager.maximize,
                  ),
                WindowCaptionButton.close(
                  brightness: Brightness.light,
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
