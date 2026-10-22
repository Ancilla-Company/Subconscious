import 'package:flutter/material.dart';

import '../forms/app_form_widgets.dart';

/// A search box: an [AppTextField] with a magnifier prefix. Pass a
/// [controller] to read or clear the text.
final class AppSearchField extends StatelessWidget {
  const AppSearchField({
    this.controller,
    this.hintText = 'Search',
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    super.key,
  });

  final TextEditingController? controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => AppTextField(
    controller: controller,
    hintText: hintText,
    autofocus: autofocus,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    textInputAction: TextInputAction.search,
    keyboardType: TextInputType.text,
    prefixIcon: const Icon(Icons.search, size: 18),
  );
}
