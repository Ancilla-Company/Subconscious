import 'package:flutter/material.dart';

final class WorkspaceImagePreview extends StatelessWidget {
  const WorkspaceImagePreview({
    required this.path,
    required this.isSvg,
    super.key,
  });

  final String path;
  final bool isSvg;

  @override
  Widget build(BuildContext context) => const Center(
    child: Text('Native image previews are unavailable on this platform.'),
  );
}
