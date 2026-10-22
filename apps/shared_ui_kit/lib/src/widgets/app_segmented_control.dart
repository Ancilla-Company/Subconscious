import 'package:flutter/material.dart';

/// One choice in an [AppSegmentedControl].
final class AppSegment<T> {
  const AppSegment({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// A single-choice segmented control that takes its look (3px corners,
/// `outlineVariant` border) from the kit theme.
final class AppSegmentedControl<T> extends StatelessWidget {
  const AppSegmentedControl({
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.expand = true,
    super.key,
  });

  final List<AppSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Stretch to the available width.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final Widget control = SegmentedButton<T>(
      showSelectedIcon: false,
      expandedInsets: expand ? EdgeInsets.zero : null,
      segments: <ButtonSegment<T>>[
        for (final AppSegment<T> segment in segments)
          ButtonSegment<T>(
            value: segment.value,
            label: Text(segment.label),
            icon: segment.icon == null ? null : Icon(segment.icon),
          ),
      ],
      selected: <T>{selected},
      onSelectionChanged: (Set<T> selection) => onChanged(selection.single),
    );
    return control;
  }
}
