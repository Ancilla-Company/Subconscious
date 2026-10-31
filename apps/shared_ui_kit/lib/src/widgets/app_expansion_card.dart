import 'package:flutter/material.dart';

import 'app_card.dart';

/// The expansion panel of the models and tools configuration: a soft card with
/// a bold [title], a one-line [subtitle], an optional short [trailingLabel] (a
/// status such as "Connected") and a chevron. Tapping the header calls
/// [onToggle]; the parent decides which panel is [expanded] (an accordion), and
/// the [child] (an editor) shows while it is open.
///
/// Without a [child] the panel has nothing to open, so it stays closed.
/// Stacked panels are spaced by [margin] (10 dp above by default).
final class AppExpansionCard extends StatelessWidget {
  const AppExpansionCard({
    required this.title,
    required this.expanded,
    required this.onToggle,
    this.subtitle,
    this.trailingLabel,
    this.child,
    this.margin = const EdgeInsets.only(top: 10),
    super.key,
  });

  final String title;
  final String? subtitle;

  /// Short status text at the end of the header, one line.
  final String? trailingLabel;
  final bool expanded;
  final VoidCallback onToggle;

  /// The details shown while the panel is open.
  final Widget? child;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => AppSectionCard(
    title: title,
    subtitle: subtitle,
    margin: margin,
    expanded: expanded && child != null,
    onToggle: onToggle,
    trailing: trailingLabel == null
        ? null
        : ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              trailingLabel!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
    child: child ?? const SizedBox.shrink(),
  );
}
