import 'dart:typed_data';

import 'package:flutter/material.dart';

final class WorkspaceDocumentPreview extends StatelessWidget {
  const WorkspaceDocumentPreview({
    required this.bytes,
    required this.kind,
    super.key,
  });

  final Uint8List bytes;
  final String kind;

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'PDF and DOCX previews are unavailable on this platform.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}
