import 'dart:typed_data';

import 'package:flutter/material.dart';

final class WorkspaceImagePreview extends StatelessWidget {
  const WorkspaceImagePreview({
    required this.bytes,
    required this.isSvg,
    super.key,
  });

  final Uint8List bytes;
  final bool isSvg;

  @override
  Widget build(BuildContext context) => const Center(
    child: Text('Native image previews are unavailable on this platform.'),
  );
}
