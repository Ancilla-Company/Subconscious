import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../controller/dashboard_controller.dart';
import 'window_caption_widgets.dart';

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
  bool _isConfirmingClose = false;
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
    if (_isClosing || _isConfirmingClose) return;
    await _captureWindowState();
    // Unsaved editor text is written out before the window goes. Nothing is
    // asked of the user unless that fails, because only then would closing
    // lose the text.
    final bool draftsStored = await widget.controller.documents
        .flushDrafts()
        .timeout(const Duration(seconds: 6), onTimeout: () => false);
    if (!draftsStored &&
        widget.controller.documents.hasUnsavedChanges &&
        !await _confirmQuitWithUnstoredChanges()) {
      return;
    }
    _isClosing = true;
    await widget.controller.flushAppState();
    await windowManager.destroy();
  }

  Future<bool> _confirmQuitWithUnstoredChanges() async {
    if (!mounted) return true;
    _isConfirmingClose = true;
    try {
      return await showDialog<bool>(
            context: context,
            builder: (BuildContext context) => AlertDialog(
              title: const Text("Unsaved changes couldn't be kept"),
              content: const Text(
                'The engine did not accept the text you have not saved yet, '
                'so it cannot be restored next time. If you quit now it is '
                'lost.',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Keep editing'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Quit anyway'),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      _isConfirmingClose = false;
    }
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
      animation: Listenable.merge(<Listenable>[
        widget.controller,
        widget.controller.settings,
      ]),
      builder: (BuildContext context, Widget? child) {
        final ThemeData theme = Theme.of(context);
        final Brightness brightness = theme.brightness;
        return ColoredBox(
          color: theme.colorScheme.surface,
          child: SizedBox(
            height: kWindowCaptionHeight,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: DragToMoveArea(
                    child: CaptionTitleContent(controller: widget.controller),
                  ),
                ),
                PanelVisibilityControls(
                  controller: widget.controller,
                  brightness: brightness,
                ),
                ThreadWorkspaceCaptionPicker(
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
