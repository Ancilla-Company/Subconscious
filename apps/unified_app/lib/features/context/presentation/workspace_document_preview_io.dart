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

final class _WorkspaceDocumentPreviewState
    extends State<WorkspaceDocumentPreview> {
  static Future<String>? _cachedViewer;
  late final Future<String> _viewer = _cachedViewer ??= _loadViewer();
  InAppWebViewController? _controller;

  static Future<String> _loadViewer() async {
    final List<String> assets = await Future.wait(<Future<String>>[
      rootBundle.loadString('assets/document_preview/viewer.html'),
      rootBundle.loadString('assets/document_preview/pdf.min.js'),
      rootBundle.loadString('assets/document_preview/pdf.worker.min.js'),
      rootBundle.loadString('assets/document_preview/jszip.min.js'),
      rootBundle.loadString('assets/document_preview/docx-preview.min.js'),
    ]);
    return assets[0]
        .replaceFirst('__PDF_JS__', base64Encode(utf8.encode(assets[1])))
        .replaceFirst('__PDF_WORKER_JS__', base64Encode(utf8.encode(assets[2])))
        .replaceFirst('__JSZIP_JS__', base64Encode(utf8.encode(assets[3])))
        .replaceFirst('__DOCX_JS__', base64Encode(utf8.encode(assets[4])));
  }

  @override
  void didUpdateWidget(covariant WorkspaceDocumentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind ||
        !listEquals(oldWidget.bytes, widget.bytes)) {
      final InAppWebViewController? controller = _controller;
      if (controller != null) _sendDocument(controller);
    }
  }

  Future<void> _sendDocument(InAppWebViewController controller) async {
    final String encoded = base64Encode(widget.bytes);
    await controller.evaluateJavascript(source: 'window.previewChunks = [];');
    const int chunkSize = 128 * 1024;
    for (var start = 0; start < encoded.length; start += chunkSize) {
      final int end = (start + chunkSize).clamp(0, encoded.length);
      final String chunk = encoded.substring(start, end);
      await controller.evaluateJavascript(
        source: 'window.previewChunks.push(${jsonEncode(chunk)});',
      );
    }
    await controller.evaluateJavascript(
      source:
          'window.renderPreview(${jsonEncode(widget.kind)}, '
          'window.previewChunks.join("")); window.previewChunks = [];',
    );
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
    return FutureBuilder<String>(
      future: _viewer,
      builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Unable to load document viewer: ${snapshot.error}'),
          );
        }
        final String? html = snapshot.data;
        if (html == null) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return InAppWebView(
          initialData: InAppWebViewInitialData(
            data: html,
            baseUrl: WebUri('https://preview.invalid/'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            supportMultipleWindows: false,
            javaScriptCanOpenWindowsAutomatically: false,
            allowFileAccessFromFileURLs: false,
            allowUniversalAccessFromFileURLs: false,
            mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
            mediaPlaybackRequiresUserGesture: true,
            disableContextMenu: true,
          ),
          onWebViewCreated: (InAppWebViewController controller) {
            _controller = controller;
          },
          onLoadStop: (InAppWebViewController controller, WebUri? url) async {
            await _sendDocument(controller);
          },
          shouldOverrideUrlLoading: (
            InAppWebViewController controller,
            NavigationAction action,
          ) async => NavigationActionPolicy.CANCEL,
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
        );
      },
    );
  }
}
