import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../tokens/app_radii.dart';

/// The app's on/off switch. It is always rectangular (a square thumb on a 3px
/// track), never the round Material switch. The normal size has a 52x30 track
/// and a 22dp thumb in a 60x48dp touch target; [compact] has a 40x24 track and a
/// 16dp thumb in a 48x32dp target. Operable with Space and Enter.
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

  /// The small version, for a switch inside a row of 32dp buttons so it does not
  /// make the row taller than its buttons.
  final bool compact;

  static const Size _normalTrack = Size(52, 30);
  static const Size _compactTrack = Size(40, 24);

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

    final Size track = compact ? _compactTrack : _normalTrack;
    final double thumb = track.height - 8;

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
            width: track.width + 8,
            height: compact ? 32 : 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: track.width,
                height: track.height,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: trackColor,
                  borderRadius: AppRadii.standard,
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 150),
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: thumb,
                    height: thumb,
                    decoration: BoxDecoration(
                      color: thumbColor,
                      borderRadius: AppRadii.standard,
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
