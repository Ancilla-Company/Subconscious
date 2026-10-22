import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      minLines: obscureText ? 1 : minLines,
      maxLines: obscureText ? 1 : maxLines,
      maxLength: maxLength,
      textAlignVertical: fixedHeight ? TextAlignVertical.center : null,
      validator: validator,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
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
      DropdownButtonFormField<String>(
        key: ValueKey<String>('$label:$value'),
        initialValue: options.contains(value) ? value : options.first,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(fontWeight: FontWeight.normal),
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
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
    initialValue: value,
    hint: hint,
    style: Theme.of(context).textTheme.bodyMedium
        ?.copyWith(fontWeight: FontWeight.normal),
    items: items,
    onChanged: onChanged,
  );
}

/// A borderless, expanded dropdown for toolbars and section headers (for
/// example the workspace filter in the threads sidebar). It is not a form
/// field: it has no fill or outline, so size it with the parent (a [SizedBox]).
final class AppCompactDropdown<T> extends StatelessWidget {
  const AppCompactDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    super.key,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;

  /// Null disables the dropdown.
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonHideUnderline(
    child: DropdownButton<T>(
      isExpanded: true,
      value: value,
      items: items,
      onChanged: onChanged,
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
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    value: value,
    onChanged: onChanged,
  );
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
