import 'package:flutter/foundation.dart';

/// The monospace family used for code and plain text.
///
/// Flutter has no generic `monospace` family on desktop, so a named font is
/// chosen per platform, with the usual alternatives as fallbacks.
String get editorMonospaceFamily => switch (defaultTargetPlatform) {
  TargetPlatform.windows => 'Consolas',
  TargetPlatform.macOS || TargetPlatform.iOS => 'Menlo',
  TargetPlatform.android => 'monospace',
  _ => 'DejaVu Sans Mono',
};

const List<String> editorMonospaceFallback = <String>[
  'Cascadia Mono',
  'Consolas',
  'Menlo',
  'DejaVu Sans Mono',
  'Liberation Mono',
  'Courier New',
  'monospace',
];
