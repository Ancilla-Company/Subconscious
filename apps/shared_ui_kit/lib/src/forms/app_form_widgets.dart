import 'package:flutter/material.dart';

import '../tokens/app_radii.dart';

import 'package:flutter/services.dart';

import '../tokens/app_spacing.dart';
import '../widgets/app_switch.dart';
import '../widgets/chiclet_menu.dart';

/// The bold label shown above a form field.
final class AppFieldLabel extends StatelessWidget {
  const AppFieldLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 18),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

/// A text field in the app's form style: an optional bold [label] above a
/// plain field that inherits [appFormTheme]. Every text input in a form,
/// settings page, dialog or sheet uses this widget, so all fields share one
/// height, border, fill and hint style on every platform.
///
/// Deliberately has no floating label, no suffix icon and no always-on helper
/// text (those change the field's height). Use [hintText] for placeholder
/// text, [helperText] only for guidance a field really needs, and
/// [validator] / [errorText] for errors.
final class AppTextField extends StatelessWidget {
  const AppTextField({
    this.label,
    this.controller,
    this.hintText,
    this.helperText,
    this.errorText,
    this.enabled = true,
    this.autofocus = false,
    this.readOnly = false,
    this.obscureText = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.autofillHints,
    this.minLines,
    this.maxLines = 1,
    this.maxLength,
    this.prefixIcon,
    this.height,
    this.validator,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.focusNode,
    this.initialValue,
    super.key,
  });

  /// Bold label above the field; null for a bare field.
  final String? label;
  final TextEditingController? controller;
  final String? initialValue;
  final String? hintText;
  final String? helperText;
  final String? errorText;
  final bool enabled;
  final bool autofocus;
  final bool readOnly;
  final bool obscureText;
  final bool autocorrect;
  final bool enableSuggestions;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;
  final int? minLines;
  final int? maxLines;
  final int? maxLength;

  /// Leading icon, for read-only value rows (paths, addresses).
  final Widget? prefixIcon;

  /// Fixed height for compact single-line value rows; null sizes to content.
  final double? height;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Called when the user finishes editing (Enter). When set, the field keeps
  /// focus instead of closing the keyboard; a find box uses it to step through
  /// matches.
  final VoidCallback? onEditingComplete;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final bool fixedHeight = height != null;
    final Widget field = TextFormField(
      controller: controller,
      initialValue: controller == null ? initialValue : null,
      focusNode: focusNode,
      enabled: enabled,
      autofocus: autofocus,
      readOnly: readOnly,
      obscureText: obscureText,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      inputFormatters: inputFormatters,
      autofillHints: autofillHints,
      // A fixed-height field fills its box. Without `expands` the field keeps
      // its content height and sits at the top of the box, so a 32 dp value
      // row drew a shorter field than the 32 dp button beside it.
      expands: fixedHeight && !obscureText,
      minLines: obscureText ? 1 : (fixedHeight ? null : minLines),
      maxLines: obscureText ? 1 : (fixedHeight ? null : maxLines),
      maxLength: maxLength,
      textAlignVertical: fixedHeight ? TextAlignVertical.center : null,
      validator: validator,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      onEditingComplete: onEditingComplete,
      decoration: InputDecoration(
        hintText: hintText,
        helperText: helperText,
        errorText: errorText,
        counterText: maxLength == null ? null : '',
        prefixIcon: prefixIcon,
        prefixIconConstraints: prefixIcon == null
            ? null
            : const BoxConstraints(minWidth: 32, minHeight: 32),
        contentPadding: fixedHeight
            ? const EdgeInsets.symmetric(horizontal: 10)
            : null,
      ),
    );
    final Widget sized = fixedHeight
        ? SizedBox(height: height, child: field)
        : field;
    if (label == null) return sized;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[AppFieldLabel(label!), sized],
    );
  }
}

/// A dropdown in the app's form style with the bold label above it.
final class AppDropdown extends StatelessWidget {
  const AppDropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      AppFieldLabel(label),
      _SelectField<String>(
        value: options.contains(value) ? value : options.first,
        items: <DropdownMenuItem<String>>[
          for (final String option in options)
            DropdownMenuItem<String>(value: option, child: Text(option)),
        ],
        onChanged: !enabled
            ? null
            : (String? next) {
                if (next != null) onChanged(next);
              },
      ),
    ],
  );
}

/// A bare dropdown in the app's form style for choices that are not plain
/// strings (rich item widgets, a nullable selection with a [hint]). Put an
/// [AppFieldLabel] above it for a label; for string options use [AppDropdown].
final class AppDropdownField<T> extends StatelessWidget {
  const AppDropdownField({
    required this.items,
    required this.onChanged,
    this.value,
    this.hint,
    super.key,
  });

  final T? value;
  final Widget? hint;
  final List<DropdownMenuItem<T>> items;

  /// Null disables the dropdown.
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) => _SelectField<T>(
    value: value,
    hint: hint,
    items: items,
    onChanged: onChanged,
  );
}

/// The kit's toolbar dropdown: a borderless, filled-on-hover button showing the
/// current choice and an arrow, for toolbars, section headers and the chat
/// composer's model picker. It is not a form field (no fill or outline at
/// rest) and is self-contained: it brings its own [height], rounded ink and
/// hover fill, so it needs no wrapper. Its width is the parent's (put it in a
/// `SizedBox` or an `Expanded`); the open list is as wide as the button.
final class AppCompactDropdown<T> extends StatelessWidget {
  const AppCompactDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    this.height = 32,
    super.key,
  });

  final T? value;
  final Widget? hint;
  final EdgeInsetsGeometry padding;

  /// Height of the button. Touch layouts pass their larger target (48).
  final double height;
  final List<DropdownMenuItem<T>> items;

  /// Null disables the dropdown.
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: _SelectField<T>(
      value: value,
      hint: hint,
      items: items,
      onChanged: onChanged,
      compact: true,
      padding: padding,
    ),
  );
}
/// An on/off row in the app's form style.
final class AppSwitchTile extends StatelessWidget {
  const AppSwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = onChanged != null;
    final Color? disabled = enabled ? null : theme.disabledColor;
    // The kit's rectangular switch, never the round Material one. Tapping the
    // text toggles it too.
    return Row(
      children: <Widget>[
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? () => onChanged!(!value) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: disabled,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: disabled ?? theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        AppSwitch(value: value, onChanged: onChanged, semanticLabel: title),
      ],
    );
  }
}

/// Inline error text for a form (an engine, network or validation failure).
final class AppFormError extends StatelessWidget {
  const AppFormError({required this.error, super.key});

  final Object error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(
      '$error',
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.error),
    ),
  );
}

/// Heading for a form or settings page.
final class AppSectionHeading extends StatelessWidget {
  const AppSectionHeading({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: Theme.of(context).textTheme.titleMedium
        ?.copyWith(fontSize: 18, fontWeight: FontWeight.bold),
  );
}

/// The right-aligned row of form buttons (Delete / Cancel / Save). Put plain
/// [FilledButton], [OutlinedButton] and [TextButton] children in it; their
/// look comes from [appFormTheme].
final class AppButtonRow extends StatelessWidget {
  const AppButtonRow({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.end,
    spacing: 8,
    runSpacing: 8,
    children: children,
  );
}

/// Centered hint shown when a list has nothing in it yet. An optional
/// [action] (for example a Retry button) sits under the message.
final class AppEmptyMessage extends StatelessWidget {
  const AppEmptyMessage(this.message, {this.action, super.key});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (action != null) ...<Widget>[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

/// A field with the buttons that act on it (copy a value, add an item, open a
/// folder) on one line. The field takes the free width; each action follows
/// after the kit's control gap, which is the same gap as between two buttons.
///
/// Use it instead of a hand-built `Row`, so field-to-button spacing is defined
/// once and matches button-to-button spacing everywhere.
final class AppFieldRow extends StatelessWidget {
  const AppFieldRow({
    required this.field,
    this.actions = const <Widget>[],
    super.key,
  });

  final Widget field;

  /// Buttons after the field, usually `AppIconButton(outlined: true)`.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(child: field),
      for (final Widget action in actions) ...<Widget>[
        AppSpacing.controlGap,
        action,
      ],
    ],
  );
}

/// The one implementation behind every dropdown. The closed field is drawn
/// here (an outlined field, or bare when [compact]); the open list is the same
/// chiclet popup menu used by `AppPopupMenu`, as wide as the field, so
/// dropdowns and popups look and size identically.
final class _SelectField<T> extends StatelessWidget {
  const _SelectField({
    required this.items,
    required this.onChanged,
    this.value,
    this.hint,
    this.compact = false,
    this.padding,
  });

  final T? value;
  final Widget? hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool compact;
  final EdgeInsetsGeometry? padding;

  Future<void> _open(BuildContext anchor) async {
    final T? chosen = await showChicletMenuBelow<T>(
      anchor: anchor,
      items: <PopupMenuEntry<T>>[
        for (final DropdownMenuItem<T> item in items)
          ChicletMenuItem<T>(
            value: item.value,
            enabled: item.enabled,
            selected: item.value == value,
            child: item.child,
          ),
      ],
    );
    if (chosen != null) onChanged?.call(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = onChanged != null && items.isNotEmpty;
    Widget? selected;
    for (final DropdownMenuItem<T> item in items) {
      if (item.value == value) selected = item.child;
    }
    final Color arrow = enabled
        ? theme.colorScheme.onSurfaceVariant
        : theme.disabledColor;
    final Widget content = DefaultTextStyle.merge(
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.normal,
        color: enabled ? null : theme.disabledColor,
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: selected ?? hint ?? const SizedBox.shrink()),
          Icon(Icons.arrow_drop_down, color: arrow),
        ],
      ),
    );
    return Builder(
      builder: (BuildContext anchor) {
        final Widget button = Semantics(
          button: true,
          enabled: enabled,
          child: InkWell(
            borderRadius: AppRadii.standard,
            onTap: enabled ? () => _open(anchor) : null,
            child: compact
                ? Padding(
                    padding: padding ?? EdgeInsets.zero,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: content,
                    ),
                  )
                : InputDecorator(
                    isEmpty: false,
                    decoration: InputDecoration(enabled: enabled),
                    child: content,
                  ),
          ),
        );
        // The toolbar dropdown paints its own ink, so it works on any surface.
        return compact
            ? Material(
                type: MaterialType.transparency,
                borderRadius: AppRadii.standard,
                clipBehavior: Clip.antiAlias,
                child: button,
              )
            : button;
      },
    );
  }
}
