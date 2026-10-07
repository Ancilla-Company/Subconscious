import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

final class WorkspaceDocumentPreview extends StatefulWidget {
  const WorkspaceDocumentPreview({
    required this.bytes,
    required this.kind,
    super.key,
  });

  final Uint8List bytes;
  final String kind;

  @override
  State<WorkspaceDocumentPreview> createState() =>
      _WorkspaceDocumentPreviewState();
}

final class _ViewerAssets {
  const _ViewerAssets({required this.html, required this.sources});

  final String html;
  final Map<String, String> sources;
}

final class _WorkspaceDocumentPreviewState
    extends State<WorkspaceDocumentPreview> {
  static const int _chunkSize = 64 * 1024;
  static const Duration _javascriptTimeout = Duration(seconds: 10);
  static const Duration _initializationTimeout = Duration(seconds: 90);
  static const Duration _renderTimeout = Duration(minutes: 2);
  static const Duration _pollInterval = Duration(milliseconds: 150);
  static Future<_ViewerAssets>? _cachedViewer;

  late final Future<_ViewerAssets> _viewer = _cachedViewer ??= _loadViewer();
  InAppWebViewController? _controller;
  Future<void> _transferQueue = Future<void>.value();
  Object? _viewerError;
  bool _pageReady = false;
  bool _librariesReady = false;
  int _pageGeneration = 0;
  int _documentGeneration = 1;
  int _scheduledDocumentGeneration = 0;
  int _initializingPageGeneration = 0;
  int _transferQueueGeneration = 0;
  int _webViewRevision = 0;
  bool _previewPointerInside = true;
  String _previewThemeJson = '{}';

  static String _cssColor(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final Color background = colors.surface;
    Color scrollbarColor(double opacity) => Color.alphaBlend(
      colors.onSurfaceVariant.withValues(alpha: opacity),
      background,
    );
    final String nextThemeJson = jsonEncode(<String, String>{
      'background': _cssColor(background),
      'foreground': _cssColor(colors.onSurface),
      'scrollbarThumb': _cssColor(scrollbarColor(0.16)),
      'scrollbarThumbHover': _cssColor(scrollbarColor(0.40)),
      'scrollbarThumbActive': _cssColor(scrollbarColor(0.72)),
      'brightness': theme.brightness == Brightness.dark ? 'dark' : 'light',
    });
    if (_previewThemeJson == nextThemeJson) return;
    _previewThemeJson = nextThemeJson;
    final InAppWebViewController? controller = _controller;
    if (controller != null && _pageReady) {
      final int generation = _pageGeneration;
      _enqueue(() => _applyPreviewTheme(controller, generation));
    }
  }

  static Future<_ViewerAssets> _loadViewer() async {
    final List<String> assets = await Future.wait(<Future<String>>[
      rootBundle.loadString('assets/document_preview/viewer.html'),
      rootBundle.loadString('assets/document_preview/pdf.min.js'),
      rootBundle.loadString('assets/document_preview/pdf.worker.min.js'),
      rootBundle.loadString('assets/document_preview/jszip.min.js'),
      rootBundle.loadString('assets/document_preview/docx-preview.min.js'),
    ]);
    return _ViewerAssets(
      html: assets[0],
      sources: <String, String>{
        'pdf': assets[1],
        'worker': assets[2],
        'jszip': assets[3],
        'docx': assets[4],
      },
    );
  }

  @override
  void didUpdateWidget(covariant WorkspaceDocumentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind == widget.kind &&
        listEquals(oldWidget.bytes, widget.bytes)) {
      return;
    }
    _documentGeneration++;
    _scheduledDocumentGeneration = 0;
    // A changed document should supersede an in-flight render immediately,
    // but viewer initialization must stay attached to its original queue.
    if (_librariesReady) _resetTransferQueue();
    _scheduleDocument();
  }

  void _resetTransferQueue() {
    _transferQueueGeneration++;
    _transferQueue = Future<void>.value();
  }

  void _enqueue(Future<void> Function() operation) {
    final int queueGeneration = _transferQueueGeneration;
    _transferQueue = _transferQueue.then((_) async {
      if (queueGeneration != _transferQueueGeneration) return;
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        if (queueGeneration != _transferQueueGeneration) return;
        debugPrint('[DocumentPreview] operation failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        _showError(error);
      }
    });
  }

  bool _isCurrentPage(InAppWebViewController _, int generation) =>
      mounted && _pageGeneration == generation && _pageReady;

  bool _isCurrentDocument(
    InAppWebViewController controller,
    int pageGeneration,
    int documentGeneration,
  ) =>
      _isCurrentPage(controller, pageGeneration) &&
      _librariesReady &&
      _documentGeneration == documentGeneration;

  void _showError(Object error) {
    if (!mounted) return;
    setState(() => _viewerError = error);
  }

  void _setLibrariesReady(InAppWebViewController controller, int generation) {
    if (!_isCurrentPage(controller, generation)) return;
    if (!_librariesReady || _viewerError != null) {
      setState(() {
        _librariesReady = true;
        _viewerError = null;
      });
    }
    _scheduleDocument();
  }

  void _handleViewerEvent(List<dynamic> arguments) {
    if (!mounted || arguments.isEmpty || arguments.first is! Map) return;
    final Map<Object?, Object?> event =
        arguments.first as Map<Object?, Object?>;
    final String? type = event['type'] as String?;
    final Object? requestId = event['requestId'];
    debugPrint('[DocumentPreview] event $type for request $requestId');
    final InAppWebViewController? controller = _controller;
    if (type == 'librariesReady' &&
        requestId == _pageGeneration &&
        controller != null) {
      _setLibrariesReady(controller, _pageGeneration);
    } else if (type == 'renderComplete' && requestId == _documentGeneration) {
      if (_viewerError != null) setState(() => _viewerError = null);
    } else if (type == 'initializationError' && requestId == _pageGeneration) {
      _showError(event['message'] ?? 'The document viewer failed.');
    } else if (type == 'renderError' && requestId == _documentGeneration) {
      _showError(event['message'] ?? 'The document could not be rendered.');
    }
  }

  Future<void> _applyPreviewTheme(
    InAppWebViewController controller,
    int generation,
  ) async {
    if (!_isCurrentPage(controller, generation)) return;
    try {
      final Object? result = await _evaluateJavascript(
        controller,
        'typeof window.setPreviewTheme === "function" && '
            'window.setPreviewTheme($_previewThemeJson);',
        'Apply document preview theme',
      );
      if (!_javascriptTrue(result)) {
        debugPrint('[DocumentPreview] viewer rejected the application theme');
      }
    } on Object catch (error) {
      // Theme synchronization is cosmetic and must not prevent rendering.
      debugPrint('[DocumentPreview] unable to apply viewer theme: $error');
    }
  }

  Duration _timeoutBefore(DateTime? deadline, String description) {
    if (deadline == null) return _javascriptTimeout;
    final Duration remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('$description timed out.');
    }
    return remaining < _javascriptTimeout ? remaining : _javascriptTimeout;
  }

  Future<dynamic> _evaluateJavascript(
    InAppWebViewController controller,
    String source,
    String description, {
    DateTime? deadline,
  }) async {
    try {
      return await controller
          .evaluateJavascript(source: source)
          .timeout(_timeoutBefore(deadline, description));
    } on Object catch (error) {
      debugPrint('[DocumentPreview] $description failed: $error');
      throw StateError('$description failed: $error');
    }
  }

  bool _javascriptTrue(Object? value) {
    if (value == true || value == 1) return true;
    if (value is! String) return false;
    final String normalized = value.trim();
    if (normalized == 'true' || normalized == '1') return true;
    try {
      final Object? decoded = jsonDecode(normalized);
      return decoded == true || decoded == 'true' || decoded == 1;
    } on FormatException {
      return false;
    }
  }

  Map<String, dynamic>? _decodeJavascriptObject(Object? value) {
    Object? decoded = value;
    for (var attempt = 0; attempt < 2 && decoded is String; attempt++) {
      try {
        decoded = jsonDecode(decoded);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) return null;
    return decoded.map<String, dynamic>(
      (Object? key, Object? item) =>
          MapEntry<String, dynamic>(key.toString(), item),
    );
  }

  int? _requestId(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  Future<void> _initializeViewer(
    InAppWebViewController controller,
    _ViewerAssets assets,
    int generation,
  ) async {
    final DateTime deadline = DateTime.now().add(_initializationTimeout);
    final Object? bootstrapResult = await _evaluateJavascript(
      controller,
      '''(() =>
        typeof window.acceptViewerSourceChunk === 'function' &&
        typeof window.finishViewerSource === 'function' &&
        typeof window.initializeViewer === 'function' &&
        typeof window.acceptPreviewChunk === 'function' &&
        typeof window.finishPreview === 'function')();''',
      'Document viewer bootstrap check',
      deadline: deadline,
    );
    if (!_javascriptTrue(bootstrapResult)) {
      throw StateError('The document viewer bootstrap did not initialize.');
    }

    for (final MapEntry<String, String> source in assets.sources.entries) {
      if (!_isCurrentPage(controller, generation)) return;
      final String encoded = base64Encode(utf8.encode(source.value));
      debugPrint(
        '[DocumentPreview] transferring ${source.key} '
        '(${encoded.length} encoded characters)',
      );
      if (encoded.isEmpty) {
        final Object? result = await _evaluateJavascript(
          controller,
          'window.acceptViewerSourceChunk('
              '${jsonEncode(source.key)}, $generation, "");',
          'Transfer ${source.key}',
          deadline: deadline,
        );
        if (!_javascriptTrue(result)) {
          throw StateError('The viewer rejected ${source.key}.');
        }
      } else {
        for (var start = 0; start < encoded.length; start += _chunkSize) {
          if (!_isCurrentPage(controller, generation)) return;
          final int end = (start + _chunkSize).clamp(0, encoded.length);
          final Object? result = await _evaluateJavascript(
            controller,
            'window.acceptViewerSourceChunk('
                '${jsonEncode(source.key)}, $generation, '
                '${jsonEncode(encoded.substring(start, end))});',
            'Transfer ${source.key}',
            deadline: deadline,
          );
          if (!_javascriptTrue(result)) {
            throw StateError('The viewer rejected ${source.key}.');
          }
        }
      }
      if (!_isCurrentPage(controller, generation)) return;
      final Object? finishResult = await _evaluateJavascript(
        controller,
        'window.finishViewerSource(${jsonEncode(source.key)}, '
            '$generation);',
        'Finish ${source.key} transfer',
        deadline: deadline,
      );
      if (!_javascriptTrue(finishResult)) {
        throw StateError('The viewer could not finish ${source.key}.');
      }
    }
    if (!_isCurrentPage(controller, generation)) return;
    await _evaluateJavascript(
      controller,
      'void window.initializeViewer($generation); true;',
      'Start document viewer initialization',
      deadline: deadline,
    );
    await _waitForLibraries(controller, generation, deadline);
    _setLibrariesReady(controller, generation);
  }

  Future<void> _waitForLibraries(
    InAppWebViewController controller,
    int generation,
    DateTime deadline,
  ) async {
    while (_isCurrentPage(controller, generation)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Document viewer initialization timed out.');
      }
      final Object? result = await _evaluateJavascript(
        controller,
        '''JSON.stringify({
          requestId: window.previewInitializationRequestId || 0,
          ready: window.previewLibrariesReady === true,
          error: window.previewInitializationError || null,
          bridgeReady: window.previewBridgeReady === true
        });''',
        'Check document viewer initialization',
        deadline: deadline,
      );
      final Map<String, dynamic>? status = _decodeJavascriptObject(result);
      if (status != null && _requestId(status['requestId']) == generation) {
        final Object? error = status['error'];
        if (error != null && error.toString().isNotEmpty) {
          throw StateError(error.toString());
        }
        if (status['ready'] == true) {
          debugPrint(
            '[DocumentPreview] libraries ready; bridge ready: '
            '${status['bridgeReady'] == true}',
          );
          return;
        }
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  void _scheduleDocument() {
    final InAppWebViewController? controller = _controller;
    final int requestId = _documentGeneration;
    final int pageGeneration = _pageGeneration;
    if (controller == null ||
        !_pageReady ||
        !_librariesReady ||
        _scheduledDocumentGeneration == requestId) {
      return;
    }
    _scheduledDocumentGeneration = requestId;
    final Uint8List bytes = Uint8List.fromList(widget.bytes);
    final String kind = widget.kind;
    if (_viewerError != null && mounted) setState(() => _viewerError = null);
    _enqueue(
      () => _sendDocument(controller, pageGeneration, requestId, kind, bytes),
    );
  }

  Future<void> _sendDocument(
    InAppWebViewController controller,
    int pageGeneration,
    int requestId,
    String kind,
    Uint8List bytes,
  ) async {
    if (!_isCurrentDocument(controller, pageGeneration, requestId)) return;
    final DateTime deadline = DateTime.now().add(_renderTimeout);
    final String encoded = base64Encode(bytes);
    debugPrint(
      '[DocumentPreview] transferring $kind document '
      '(${encoded.length} encoded characters)',
    );
    if (encoded.isEmpty) {
      final Object? result = await _evaluateJavascript(
        controller,
        'window.acceptPreviewChunk($requestId, "");',
        'Transfer document',
        deadline: deadline,
      );
      if (!_javascriptTrue(result)) {
        throw StateError('The viewer rejected the document.');
      }
    } else {
      for (var start = 0; start < encoded.length; start += _chunkSize) {
        if (!_isCurrentDocument(controller, pageGeneration, requestId)) {
          return;
        }
        final int end = (start + _chunkSize).clamp(0, encoded.length);
        final Object? result = await _evaluateJavascript(
          controller,
          'window.acceptPreviewChunk($requestId, '
              '${jsonEncode(encoded.substring(start, end))});',
          'Transfer document',
          deadline: deadline,
        );
        if (!_javascriptTrue(result)) {
          throw StateError('The viewer rejected the document.');
        }
      }
    }
    if (!_isCurrentDocument(controller, pageGeneration, requestId)) return;
    await _evaluateJavascript(
      controller,
      'void window.finishPreview($requestId, ${jsonEncode(kind)}); true;',
      'Start document rendering',
      deadline: deadline,
    );
    await _waitForRender(controller, pageGeneration, requestId, deadline);
    if (_isCurrentDocument(controller, pageGeneration, requestId) &&
        _viewerError != null) {
      setState(() => _viewerError = null);
    }
  }

  Future<void> _waitForRender(
    InAppWebViewController controller,
    int pageGeneration,
    int requestId,
    DateTime deadline,
  ) async {
    while (_isCurrentDocument(controller, pageGeneration, requestId)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Document rendering timed out.');
      }
      final Object? result = await _evaluateJavascript(
        controller,
        '''JSON.stringify({
          requestId: window.previewRenderRequestId || 0,
          complete: window.previewRenderComplete === true,
          error: window.previewRenderError || null
        });''',
        'Check document rendering',
        deadline: deadline,
      );
      final Map<String, dynamic>? status = _decodeJavascriptObject(result);
      if (status != null && _requestId(status['requestId']) == requestId) {
        final Object? error = status['error'];
        if (error != null && error.toString().isNotEmpty) {
          throw StateError('Document rendering failed: $error');
        }
        if (status['complete'] == true) return;
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  void _setPreviewPointerInside(bool inside) {
    _previewPointerInside = inside;
    final InAppWebViewController? controller = _controller;
    final int generation = _pageGeneration;
    if (controller == null || !_pageReady) return;
    unawaited(_updatePreviewPointerBoundary(controller, generation, inside));
  }

  Future<void> _updatePreviewPointerBoundary(
    InAppWebViewController controller,
    int generation,
    bool inside,
  ) async {
    if (!_isCurrentPage(controller, generation)) return;
    try {
      await controller
          .evaluateJavascript(
            source:
                'typeof window.setPreviewPointerInside === "function" && '
                'window.setPreviewPointerInside($inside);',
          )
          .timeout(const Duration(seconds: 1));
    } on Object catch (error) {
      if (_isCurrentPage(controller, generation)) {
        debugPrint('[DocumentPreview] pointer boundary update failed: $error');
      }
    }
  }

  void _startViewerInitialization(
    _ViewerAssets assets, {
    required String trigger,
    WebUri? url,
  }) {
    final InAppWebViewController? controller = _controller;
    if (!mounted || controller == null) return;
    _pageReady = true;
    _setPreviewPointerInside(_previewPointerInside);
    final int generation = _pageGeneration;
    if (_initializingPageGeneration == generation) return;
    _initializingPageGeneration = generation;
    debugPrint(
      '[DocumentPreview] page ready via $trigger ($url), initializing '
      'generation $generation',
    );
    _enqueue(() async {
      await _applyPreviewTheme(controller, generation);
      await _initializeViewer(controller, assets, generation);
    });
  }

  void _beginWebView(InAppWebViewController controller) {
    _pageGeneration++;
    _controller = controller;
    _pageReady = false;
    _librariesReady = false;
    _scheduledDocumentGeneration = 0;
    _initializingPageGeneration = 0;
    _resetTransferQueue();
    debugPrint(
      '[DocumentPreview] WebView created for generation $_pageGeneration',
    );
    controller.addJavaScriptHandler(
      handlerName: 'documentPreviewEvent',
      callback: (List<dynamic> arguments) {
        _handleViewerEvent(arguments);
        return null;
      },
    );
  }

  void _retry() {
    _pageGeneration++;
    _documentGeneration++;
    _controller = null;
    _pageReady = false;
    _librariesReady = false;
    _scheduledDocumentGeneration = 0;
    _initializingPageGeneration = 0;
    _resetTransferQueue();
    setState(() {
      _viewerError = null;
      _webViewRevision++;
    });
  }

  @override
  void dispose() {
    _pageGeneration++;
    _documentGeneration++;
    _controller = null;
    _pageReady = false;
    _librariesReady = false;
    _resetTransferQueue();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'PDF and DOCX previews are unavailable on Linux.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return FutureBuilder<_ViewerAssets>(
      future: _viewer,
      builder: (BuildContext context, AsyncSnapshot<_ViewerAssets> snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Unable to load document viewer: ${snapshot.error}'),
          );
        }
        final _ViewerAssets? assets = snapshot.data;
        if (assets == null) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            MouseRegion(
              onEnter: (_) => _setPreviewPointerInside(true),
              onExit: (_) => _setPreviewPointerInside(false),
              child: InAppWebView(
                key: ValueKey<int>(_webViewRevision),
                initialData: InAppWebViewInitialData(
                  data: assets.html,
                  baseUrl: WebUri('https://preview.invalid/'),
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  supportMultipleWindows: false,
                  javaScriptCanOpenWindowsAutomatically: false,
                  allowFileAccessFromFileURLs: false,
                  allowUniversalAccessFromFileURLs: false,
                  mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                  mediaPlaybackRequiresUserGesture: true,
                  disableContextMenu: true,
                ),
                onWebViewCreated: _beginWebView,
                onProgressChanged: (InAppWebViewController _, int progress) {
                  if (progress != 100) return;
                  final int generation = _pageGeneration;
                  unawaited(
                    Future<void>.delayed(const Duration(milliseconds: 250), () {
                      if (generation == _pageGeneration &&
                          _initializingPageGeneration != generation) {
                        _startViewerInitialization(
                          assets,
                          trigger: 'progress fallback',
                        );
                      }
                    }),
                  );
                },
                onLoadStop: (InAppWebViewController _, WebUri? url) {
                  _startViewerInitialization(
                    assets,
                    trigger: 'onLoadStop',
                    url: url,
                  );
                },
                onConsoleMessage:
                    (
                      InAppWebViewController controller,
                      ConsoleMessage message,
                    ) {
                      debugPrint(
                        '[DocumentPreview][${message.messageLevel}] '
                        '${message.message}',
                      );
                    },
                onReceivedError:
                    (
                      InAppWebViewController _,
                      WebResourceRequest request,
                      WebResourceError error,
                    ) {
                      debugPrint(
                        '[DocumentPreview] WebView load error '
                        '${error.type}: ${error.description}',
                      );
                      if (_controller != null &&
                          request.isForMainFrame == true) {
                        _showError(
                          'The document preview page failed to load: '
                          '${error.description}',
                        );
                      }
                    },
                onCreateWindow: (
                  InAppWebViewController controller,
                  CreateWindowAction action,
                ) async => false,
                onDownloadStartRequest: (
                  InAppWebViewController controller,
                  DownloadStartRequest request,
                ) async {},
                onPermissionRequest:
                    (
                      InAppWebViewController controller,
                      PermissionRequest request,
                    ) async => PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.DENY,
                    ),
                onReceivedServerTrustAuthRequest:
                    (
                      InAppWebViewController controller,
                      URLAuthenticationChallenge challenge,
                    ) async => ServerTrustAuthResponse(
                      action: ServerTrustAuthResponseAction.CANCEL,
                    ),
              ),
            ),
            if (_viewerError case final Object error)
              ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'Unable to display this document.\n$error',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _retry,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
