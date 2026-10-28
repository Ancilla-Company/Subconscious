import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The app's rectangular on/off switch: a 40x24 track with a square thumb,
/// 3px corners, in a 48dp touch target (32dp when [compact]). Operable with Space and Enter.
///
/// [semanticLabel] names the control for screen readers; a null [onChanged]
/// disables it.
final class AppSwitch extends StatelessWidget {
  const AppSwitch({
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.compact = false,
    super.key,
  });

  /// A 32dp tall touch target instead of 48dp, for a switch inside a row of
  /// 32dp buttons, so it does not make the row taller than its buttons.
  final bool compact;

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool enabled = onChanged != null;
    final Color trackColor = enabled
        ? (value ? colors.primary : colors.surfaceContainerHighest)
        : (value
              ? colors.primary.withValues(alpha: 0.38)
              : colors.onSurface.withValues(alpha: 0.12));
    final Color thumbColor = enabled
        ? (value ? colors.onPrimary : colors.onSurfaceVariant)
        : colors.onSurface.withValues(alpha: 0.38);

    void toggle() => onChanged?.call(!value);

    return Semantics(
      label: semanticLabel,
      button: true,
      enabled: enabled,
      toggled: value,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? toggle : null,
          child: SizedBox(
            width: 48,
            height: compact ? 32 : 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 40,
                height: 24,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: trackColor,
                  borderRadius: const BorderRadius.all(Radius.circular(3)),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 150),
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: thumbColor,
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
