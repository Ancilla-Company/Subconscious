import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../../diagnostics/gui_log.dart';
import '../controller/dashboard_controller.dart';
import '../controller/shutdown_coordinator.dart';
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
  const EngineCompositionBar({
    required this.controller,
    this.onToggleFlyout,
    super.key,
  });

  final DashboardController controller;

  /// Adds a flyout button before the logo (the chat-only window).
  final VoidCallback? onToggleFlyout;

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
    widget.controller.onEngineQuit = () => unawaited(_closeWindow());
    widget.controller.chatOnlyWindowHandler = _applyChatOnly;
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

  /// A window position worth restoring: big enough to use, and with its title
  /// bar on a screen that is still connected. A minimized window reports
  /// (-32000, -32000); saving that, or a monitor that was unplugged, starts the
  /// next launch invisible, with the app running and no window to see.
  Future<bool> _isUsableBounds(Rect bounds) async {
    final bool sane =
        bounds.left.isFinite &&
        bounds.top.isFinite &&
        bounds.width >= 400 &&
        bounds.height >= 300 &&
        bounds.width < 20000 &&
        bounds.height < 20000;
    if (!sane) return false;
    try {
      final Rect titleBar = Rect.fromLTWH(
        bounds.left,
        bounds.top,
        bounds.width,
        48,
      );
      for (final Display display in await screenRetriever.getAllDisplays()) {
        final Rect area =
            (display.visiblePosition ?? Offset.zero) &
            (display.visibleSize ?? display.size);
        final Rect overlap = area.intersect(titleBar);
        if (overlap.width >= 100 && overlap.height >= 24) return true;
      }
      return false;
    } on Object catch (error) {
      guiLog('Could not read the displays: $error', level: 'WARNING');
      return bounds.left > -10000 && bounds.top > -10000;
    }
  }

  Future<void> _restoreWindowState() async {
    _isRestoringWindowState = true;
    bool captureInitialBounds = !widget.controller.hasWindowBounds;
    try {
      if (widget.controller.hasWindowBounds) {
        final Rect saved = Rect.fromLTWH(
          widget.controller.windowX!,
          widget.controller.windowY!,
          widget.controller.windowWidth!,
          widget.controller.windowHeight!,
        );
        if (await _isUsableBounds(saved)) {
          guiLog('Restoring window bounds $saved');
          await windowManager.setBounds(saved);
        } else {
          guiLog(
            'Saved window bounds $saved are off screen or unusable; '
            'centring the window instead',
            level: 'WARNING',
          );
          await windowManager.setSize(const Size(1280, 720));
          await windowManager.center();
          captureInitialBounds = true;
        }
      }
      if (widget.controller.windowMaximized) {
        await windowManager.maximize();
      } else if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      }
      if (await windowManager.isMinimized()) await windowManager.restore();
      if (!await windowManager.isVisible()) {
        guiLog(
          'The window was hidden after start-up; showing it',
          level: 'WARNING',
        );
        await windowManager.show();
      }
      _isMaximized = await windowManager.isMaximized();
      _hasRestoredWindowState = true;
      guiLog('Window state restored (maximized=$_isMaximized)');
      if (mounted) setState(() {});
    } on Object catch (error, stack) {
      guiLogError('Restoring the window state failed', error, stack);
      try {
        await windowManager.show();
      } on Object {
        // Nothing more can be done.
      }
    } finally {
      _isRestoringWindowState = false;
    }
    if (captureInitialBounds) await _captureWindowState();
  }

  Rect? _boundsBeforeChatOnly;
  bool _maximizedBeforeChatOnly = false;

  /// The small, always-on-top chat window and the way back from it.
  Future<void> _applyChatOnly(bool enabled) async {
    if (enabled) {
      _maximizedBeforeChatOnly = await windowManager.isMaximized();
      if (_maximizedBeforeChatOnly) await windowManager.unmaximize();
      _boundsBeforeChatOnly = await windowManager.getBounds();
      await windowManager.setMinimumSize(const Size(360, 360));
      await windowManager.setSize(const Size(420, 720));
      await windowManager.setAlwaysOnTop(true);
      return;
    }
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setMinimumSize(const Size(800, 560));
    final Rect? bounds = _boundsBeforeChatOnly;
    _boundsBeforeChatOnly = null;
    if (bounds != null) await windowManager.setBounds(bounds);
    if (_maximizedBeforeChatOnly) await windowManager.maximize();
  }

  Future<void> _captureWindowState() async {
    // The small chat window is temporary; keep the real size for next time.
    if (widget.controller.chatOnly) return;
    if (!_hasRestoredWindowState || _isRestoringWindowState || _isClosing) {
      return;
    }
    // A minimized window reports a position far off screen; keep the last good one.
    if (await windowManager.isMinimized()) return;
    final bool maximized = await windowManager.isMaximized();
    if (maximized) {
      widget.controller.updateWindowState(windowMaximized: true);
      return;
    }
    final Rect bounds = await windowManager.getBounds();
    if (!await _isUsableBounds(bounds)) {
      guiLog('Not saving unusable window bounds $bounds', level: 'WARNING');
      return;
    }
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
        .timeout(const Duration(milliseconds: 600), onTimeout: () => false);
    if (!draftsStored &&
        widget.controller.documents.hasUnsavedChanges &&
        !await _confirmQuitWithUnstoredChanges()) {
      return;
    }
    _isClosing = true;
    // Backstop: whatever hangs, the process is gone within two seconds.
    Timer(const Duration(seconds: 2), () => exit(0));
    // Hide first so closing feels instant; cleanup then runs under a hard
    // deadline. The engine keeps running: only this window's own timers and
    // sockets are torn down.
    await windowManager.hide();
    await ShutdownCoordinator(
      onFailure: (String name, Object error) =>
          debugPrint('Shutdown task $name did not finish cleanly: $error'),
    ).run(<ShutdownTask>[
      ShutdownTask(
        'appState',
        widget.controller.flushAppState,
        timeout: const Duration(milliseconds: 800),
      ),
      ShutdownTask(
        'sockets',
        widget.controller.shutdownConnections,
        timeout: const Duration(milliseconds: 500),
      ),
    ]);
    exit(0);
  }

  Future<bool> _confirmQuitWithUnstoredChanges() async {
    if (!mounted) return true;
    _isConfirmingClose = true;
    try {
      return await showAppDialog<bool>(
            context: context,
            builder: (BuildContext context) => AppDialog(
              title: "Unsaved changes couldn't be kept",
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
      widget.controller.onEngineQuit = null;
      widget.controller.chatOnlyWindowHandler = null;
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
    if (_hasRestoredWindowState &&
        !_isRestoringWindowState &&
        !widget.controller.chatOnly) {
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
    guiLog('Window close requested');
    unawaited(_closeWindow());
  }

  @override
  void onWindowMinimize() => guiLog('Window minimized');

  @override
  void onWindowRestore() => guiLog('Window restored');

  @override
  void onWindowFocus() => guiLog('Window focused');

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
                // Outside the drag area: a press there starts a window drag.
                if (widget.onToggleFlyout case final VoidCallback toggle)
                  CaptionFlyoutButton(
                    brightness: brightness,
                    onPressed: toggle,
                  ),
                Expanded(
                  child: DragToMoveArea(
                    child: CaptionTitleContent(
                      controller: widget.controller,
                      compact: widget.controller.chatOnly,
                    ),
                  ),
                ),
                PanelVisibilityControls(
                  controller: widget.controller,
                  brightness: brightness,
                ),
                // No room for the workspace picker in the small chat window.
                if (!widget.controller.chatOnly)
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
