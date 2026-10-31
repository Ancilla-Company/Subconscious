import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import 'find_model.dart';

/// The find and replace bar shown over a text editor.
///
/// It owns no text of its own: the editor passes the document text through
/// [textProvider], and acts on the matches and replacements the [model]
/// describes.
final class EditorFindBar extends StatefulWidget {
  const EditorFindBar({
    required this.model,
    required this.queryFocus,
    required this.textProvider,
    required this.anchorProvider,
    required this.onJump,
    required this.onReplace,
    required this.onReplaceAll,
    required this.onClose,
    super.key,
  });

  final FindModel model;
  final FocusNode queryFocus;

  /// The current document text.
  final String Function() textProvider;

  /// Where searching starts from, normally the caret.
  final int Function() anchorProvider;

  /// Selects and reveals a match.
  final void Function(TextRange match) onJump;
  final VoidCallback onReplace;
  final VoidCallback onReplaceAll;
  final VoidCallback onClose;

  @override
  State<EditorFindBar> createState() => _EditorFindBarState();
}

final class _EditorFindBarState extends State<EditorFindBar> {
  late final TextEditingController _query;
  late final TextEditingController _replacement;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController(text: widget.model.query);
    _replacement = TextEditingController(text: widget.model.replacement);
    widget.model.addListener(_onModelChanged);
    widget.queryFocus.addListener(_onQueryFocus);
  }

  @override
  void didUpdateWidget(covariant EditorFindBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_onModelChanged);
      widget.model.addListener(_onModelChanged);
    }
    if (oldWidget.queryFocus != widget.queryFocus) {
      oldWidget.queryFocus.removeListener(_onQueryFocus);
      widget.queryFocus.addListener(_onQueryFocus);
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    widget.queryFocus.removeListener(_onQueryFocus);
    _query.dispose();
    _replacement.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    // The editor fills the query from the selection; mirror it in the field.
    if (_query.text != widget.model.query) {
      _query.value = TextEditingValue(
        text: widget.model.query,
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: widget.model.query.length,
        ),
      );
    }
    if (mounted) setState(() {});
  }

  void _onQueryFocus() {
    if (widget.queryFocus.hasFocus) {
      _query.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _query.text.length,
      );
    }
  }

  void _configure({
    String? query,
    bool? caseSensitive,
    bool? wholeWord,
    bool? useRegex,
  }) {
    widget.model.configure(
      query: query,
      caseSensitive: caseSensitive,
      wholeWord: wholeWord,
      useRegex: useRegex,
      text: widget.textProvider(),
      anchor: widget.anchorProvider(),
    );
    final TextRange? match = widget.model.currentMatch;
    if (match != null) widget.onJump(match);
  }

  void _step({required bool forward}) {
    if (widget.model.matches.isEmpty) {
      // Matches may be stale if the text changed since the last search.
      widget.model.recompute(
        widget.textProvider(),
        anchor: widget.anchorProvider(),
      );
    }
    final TextRange? match = forward
        ? widget.model.next()
        : widget.model.previous();
    if (match != null) widget.onJump(match);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FindModel model = widget.model;
    final String summary;
    if (model.error != null) {
      summary = 'Invalid pattern';
    } else if (model.query.isEmpty) {
      summary = '';
    } else if (model.matches.isEmpty) {
      summary = 'No results';
    } else {
      summary =
          '${model.current + 1} of ${model.matches.length}${model.capped ? '+' : ''}';
    }
    return Theme(
      data: appFormTheme(context),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): () =>
              _step(forward: true),
          const SingleActivator(LogicalKeyboardKey.enter, shift: true): () =>
              _step(forward: false),
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        },
        child: Material(
          elevation: 4,
          color: colors.surfaceContainerHigh,
          borderRadius: AppRadii.standard,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      AppIconButton(
                        icon: model.replaceVisible
                            ? FluentIcons.chevron_down_20_regular
                            : FluentIcons.chevron_right_20_regular,
                        tooltip: model.replaceVisible
                            ? 'Hide replace'
                            : 'Show replace',

                        onPressed: model.toggleReplace,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: AppTextField(
                          controller: _query,
                          focusNode: widget.queryFocus,
                          hintText: 'Find',
                          height: 32,
                          onChanged: (String value) => _configure(query: value),
                          // Enter steps to the next match; focus stays here.
                          onEditingComplete: () {},
                        ),
                      ),
                      const SizedBox(width: 4),
                      AppTextToggle(
                        label: 'Aa',
                        tooltip: 'Match case',
                        selected: model.caseSensitive,
                        onPressed: () =>
                            _configure(caseSensitive: !model.caseSensitive),
                      ),
                      AppTextToggle(
                        label: 'ab',
                        tooltip: 'Whole word',
                        selected: model.wholeWord,
                        underline: true,
                        onPressed: () =>
                            _configure(wholeWord: !model.wholeWord),
                      ),
                      AppTextToggle(
                        label: '.*',
                        tooltip: 'Regular expression',
                        selected: model.useRegex,
                        onPressed: () => _configure(useRegex: !model.useRegex),
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 56),
                        child: Text(
                          summary,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: model.error != null
                                    ? colors.error
                                    : colors.onSurfaceVariant,
                              ),
                        ),
                      ),
                      AppIconButton(
                        icon: FluentIcons.arrow_up_20_regular,
                        tooltip: 'Previous match (Shift+Enter)',

                        onPressed: () => _step(forward: false),
                      ),
                      AppIconButton(
                        icon: FluentIcons.arrow_down_20_regular,
                        tooltip: 'Next match (Enter)',

                        onPressed: () => _step(forward: true),
                      ),
                      AppIconButton(
                        icon: FluentIcons.dismiss_20_regular,
                        tooltip: 'Close (Esc)',

                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  if (model.replaceVisible)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 32),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: CallbackShortcuts(
                              bindings: <ShortcutActivator, VoidCallback>{
                                const SingleActivator(
                                  LogicalKeyboardKey.enter,
                                ): widget.onReplace,
                              },
                              child: AppTextField(
                                controller: _replacement,
                                hintText: 'Replace',
                                height: 32,
                                onChanged: widget.model.setReplacement,
                                onEditingComplete: () {},
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          SizedBox(
                            height: 32,
                            child: TextButton(
                              onPressed: model.matches.isEmpty
                                  ? null
                                  : widget.onReplace,
                              child: const Text('Replace'),
                            ),
                          ),
                          SizedBox(
                            height: 32,
                            child: TextButton(
                              onPressed: model.matches.isEmpty
                                  ? null
                                  : widget.onReplaceAll,
                              child: const Text('All'),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
