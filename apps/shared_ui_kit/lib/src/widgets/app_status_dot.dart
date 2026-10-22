import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';

/// Connection state shown by an [AppStatusDot].
enum AppStatus {
  connected(AppColors.statusConnected, 'connected'),
  connecting(AppColors.statusConnecting, 'connecting'),
  disconnected(AppColors.statusDisconnected, 'disconnected');

  const AppStatus(this.color, this.defaultLabel);

  /// The token colour for this state.
  final Color color;
  final String defaultLabel;
}

/// A small coloured dot for a connection state, with an optional text label.
/// The colours are the `AppColors.status*` tokens.
final class AppStatusDot extends StatelessWidget {
  const AppStatusDot({
    required this.status,
    this.label,
    this.showLabel = true,
    this.size = 8,
    super.key,
  });

  final AppStatus status;

  /// Text next to the dot; defaults to the state name.
  final String? label;

  /// Hide to show only the dot (the label still names it for screen readers).
  final bool showLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final String text = label ?? status.defaultLabel;
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              color: status.color,
              shape: BoxShape.circle,
            ),
            child: SizedBox.square(dimension: size),
          ),
          if (showLabel) ...<Widget>[
            const SizedBox(width: 6),
            Text(text, style: Theme.of(context).textTheme.labelMedium),
          ],
        ],
      ),
    );
  }
}
