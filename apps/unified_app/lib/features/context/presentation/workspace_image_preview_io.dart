import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

final class WorkspaceImagePreview extends StatelessWidget {
  const WorkspaceImagePreview({
    required this.path,
    required this.isSvg,
    super.key,
  });

  final String path;
  final bool isSvg;

  @override
  Widget build(BuildContext context) => InteractiveViewer(
    minScale: 0.1,
    maxScale: 10,
    boundaryMargin: const EdgeInsets.all(80),
    child: Center(
      child: isSvg
          ? SvgPicture.file(
              File(path),
              fit: BoxFit.contain,
              placeholderBuilder: (BuildContext context) =>
                  const CircularProgressIndicator(strokeWidth: 2),
            )
          : Image.file(
              File(path),
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
