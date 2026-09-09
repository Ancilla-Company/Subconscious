import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

final class WorkspaceImagePreview extends StatelessWidget {
  const WorkspaceImagePreview({
    required this.bytes,
    required this.isSvg,
    super.key,
  });

  final Uint8List bytes;
  final bool isSvg;

  @override
  Widget build(BuildContext context) => InteractiveViewer(
    minScale: 0.1,
    maxScale: 10,
    boundaryMargin: const EdgeInsets.all(80),
    child: Center(
      child: isSvg
          ? SvgPicture.memory(
              bytes,
              fit: BoxFit.contain,
              placeholderBuilder: (BuildContext context) =>
                  const CircularProgressIndicator(strokeWidth: 2),
            )
          : Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (
                BuildContext context,
                Object error,
                StackTrace? stack,
              ) => Text('Unable to preview image: $error'),
            ),
    ),
  );
}
