import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

/// One tab in the editor's tab bar.
///
/// A dot marks unsaved changes and a warning icon marks a file that no longer
/// matches the disk. A middle click closes the tab, as in most editors.
final class FileTabButton extends StatelessWidget {
  const FileTabButton({
    required this.label,
    required this.selected,
    required this.dirty,
    required this.onTap,
    required this.onClose,
    this.warning = false,
    super.key,
  });

  final String label;
  final bool selected;
  final bool dirty;
  final bool warning;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Listener(
        onPointerDown: (PointerDownEvent event) {
          if (event.buttons == kMiddleMouseButton) onClose();
        },
        child: Material(
          color: selected
              ? colors.secondaryContainer
              : colors.surfaceContainerLow,
          borderRadius: AppRadii.standard,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 32,
              child: Padding(
                padding: const EdgeInsets.only(left: 10, right: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (warning) ...<Widget>[
                      Icon(
                        FluentIcons.warning_20_regular,
                        size: 14,
                        color: colors.error,
                      ),
                      const SizedBox(width: 5),
                    ],
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: selected ? colors.onSecondaryContainer : null,
                        ),
                      ),
                    ),
                    if (dirty) ...<Widget>[
                      const SizedBox(width: 7),
                      Semantics(
                        label: 'Unsaved changes',
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: colors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 3),
                    AppIconButton(
                      tooltip: 'Close $label',
                      onPressed: onClose,
                      icon: FluentIcons.dismiss_20_regular,
                      iconSize: 13,
                      size: AppIconButtonSize.tiny,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
