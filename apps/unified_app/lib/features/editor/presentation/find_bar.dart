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
    final InputDecoration decoration = InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
    );
    return CallbackShortcuts(
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
        borderRadius: BorderRadius.circular(8),
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
                    SidebarButton(
                      icon: model.replaceVisible
                          ? FluentIcons.chevron_down_20_regular
                          : FluentIcons.chevron_right_20_regular,
                      selectedIcon: model.replaceVisible
                          ? FluentIcons.chevron_down_20_regular
                          : FluentIcons.chevron_right_20_regular,
                      tooltip: model.replaceVisible
                          ? 'Hide replace'
                          : 'Show replace',
                      dimension: 28,
                      onPressed: model.toggleReplace,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: SizedBox(
                        height: 32,
                        child: TextField(
                          controller: _query,
                          focusNode: widget.queryFocus,
                          decoration: decoration.copyWith(
                            hintText: 'Find',
                            errorText: null,
                          ),
                          style: Theme.of(context).textTheme.bodyMedium,
                          onChanged: (String value) =>
                              _configure(query: value),
                          onEditingComplete: () {},
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _FindToggle(
                      label: 'Aa',
                      tooltip: 'Match case',
                      selected: model.caseSensitive,
                      onPressed: () =>
                          _configure(caseSensitive: !model.caseSensitive),
                    ),
                    _FindToggle(
                      label: 'ab',
                      tooltip: 'Whole word',
                      selected: model.wholeWord,
                      underline: true,
                      onPressed: () => _configure(wholeWord: !model.wholeWord),
                    ),
                    _FindToggle(
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: model.error != null
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    SidebarButton(
                      icon: FluentIcons.arrow_up_20_regular,
                      selectedIcon: FluentIcons.arrow_up_20_regular,
                      tooltip: 'Previous match (Shift+Enter)',
                      dimension: 28,
                      onPressed: () => _step(forward: false),
                    ),
                    SidebarButton(
                      icon: FluentIcons.arrow_down_20_regular,
                      selectedIcon: FluentIcons.arrow_down_20_regular,
                      tooltip: 'Next match (Enter)',
                      dimension: 28,
                      onPressed: () => _step(forward: true),
                    ),
                    SidebarButton(
                      icon: FluentIcons.dismiss_20_regular,
                      selectedIcon: FluentIcons.dismiss_20_regular,
                      tooltip: 'Close (Esc)',
                      dimension: 28,
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
                          child: SizedBox(
                            height: 32,
                            child: CallbackShortcuts(
                              bindings: <ShortcutActivator, VoidCallback>{
                                const SingleActivator(LogicalKeyboardKey.enter):
                                    widget.onReplace,
                              },
                              child: TextField(
                                controller: _replacement,
                                decoration: decoration.copyWith(
                                  hintText: 'Replace',
                                ),
                                style: Theme.of(context).textTheme.bodyMedium,
                                onChanged: widget.model.setReplacement,
                                onEditingComplete: () {},
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          onPressed: model.matches.isEmpty
                              ? null
                              : widget.onReplace,
                          child: const Text('Replace'),
                        ),
                        TextButton(
                          onPressed: model.matches.isEmpty
                              ? null
                              : widget.onReplaceAll,
                          child: const Text('All'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small toggle that shows a short text label, like the case and word
/// options of a find bar.
final class _FindToggle extends StatelessWidget {
  const _FindToggle({
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
    this.underline = false,
  });

  final String label;
  final String tooltip;
  final bool selected;
  final bool underline;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: selected,
        label: tooltip,
        child: SizedBox.square(
          dimension: 28,
          child: Material(
            color: selected ? colors.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              canRequestFocus: false,
              onTap: onPressed,
              child: Center(
                child: ExcludeSemantics(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      decoration: underline
                          ? TextDecoration.underline
                          : TextDecoration.none,
                      color: selected
                          ? colors.onSecondaryContainer
                          : colors.onSurfaceVariant,
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
