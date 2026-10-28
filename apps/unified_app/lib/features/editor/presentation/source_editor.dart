import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/editor_document_store.dart';
import '../controller/editor_tab.dart';
import 'editor_fonts.dart';
import 'editor_text_controller.dart';
import 'find_bar.dart';
import 'find_model.dart';
import 'markdown/markdown_commands.dart';
import 'markdown/markdown_preview.dart';
import 'markdown/markdown_ribbon.dart';

/// Finds the state of the text field inside [context], to reach the scroll
/// helpers that a text field does not expose directly.
EditableTextState? findEditableTextState(BuildContext? context) {
  if (context is! Element) return null;
  EditableTextState? found;
  void visit(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is EditableTextState) {
      found = element.state as EditableTextState;
      return;
    }
    element.visitChildren(visit);
  }

  context.visitChildren(visit);
  return found;
}

/// A source-first editor for markdown and plain text.
///
/// The text is edited exactly as it is stored: markdown keeps its syntax
/// characters, which are styled rather than hidden, so nothing is rewritten
/// behind the user's back. Both kinds get find and replace, undo, selection
/// by double and triple click, and a Tab key that indents.
final class SourceEditor extends StatefulWidget {
  const SourceEditor({
    required this.store,
    required this.tab,
    required this.markdown,
    this.viewMode = MarkdownViewMode.edit,
    this.onViewModeChanged,
    this.autofocus = false,
    super.key,
  });

  final EditorDocumentStore store;
  final TextTab tab;

  /// Whether this is a markdown file, which adds the ribbon, live styling,
  /// list continuation and the preview.
  final bool markdown;
  final MarkdownViewMode viewMode;
  final ValueChanged<MarkdownViewMode>? onViewModeChanged;
  final bool autofocus;

  @override
  State<SourceEditor> createState() => _SourceEditorState();
}

final class _SourceEditorState extends State<SourceEditor> {
  late final EditorTextController _controller;
  late final ScrollController _scroll;
  late final List<TextInputFormatter> _formatters;
  final FocusNode _focus = FocusNode(debugLabel: 'editor text');
  final FocusNode _findFocus = FocusNode(debugLabel: 'editor find');
  final FindModel _find = FindModel();
  final GlobalKey _fieldKey = GlobalKey();
  String _lastText = '';

  TextTab get _tab => widget.tab;

  @override
  void initState() {
    super.initState();
    final TextTab tab = widget.tab;
    _lastText = tab.text;
    final bool rawBreaks = !tab.crlf && tab.text.contains('\r');
    _formatters = <TextInputFormatter>[
      if (!rawBreaks) const NormalizeNewlinesFormatter(),
      if (widget.markdown) const MarkdownEnterFormatter(),
    ];
    _controller = widget.markdown
        ? MarkdownTextController(text: tab.text, styled: !tab.isLarge)
        : EditorTextController(text: tab.text);
    final int length = tab.text.length;
    if (tab.selection.isValid) {
      _controller.selection = TextSelection(
        baseOffset: tab.selection.baseOffset.clamp(0, length),
        extentOffset: tab.selection.extentOffset.clamp(0, length),
      );
    }
    _scroll = ScrollController(initialScrollOffset: tab.scrollOffset)
      ..addListener(_rememberScroll);
    _controller.addListener(_onControllerChanged);
    _find.addListener(_onFindChanged);
    if (tab.scrollOffset == 0 &&
        tab.selection.isValid &&
        tab.selection.start > 0) {
      // A restored caret far down the file should be in view.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reveal(_controller.selection.extentOffset);
      });
    }
  }

  @override
  void dispose() {
    _find.removeListener(_onFindChanged);
    _controller.removeListener(_onControllerChanged);
    _scroll.removeListener(_rememberScroll);
    if (_controller.selection.isValid) _tab.selection = _controller.selection;
    _find.dispose();
    _controller.dispose();
    _scroll.dispose();
    _focus.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  void _rememberScroll() {
    if (_scroll.hasClients) _tab.scrollOffset = _scroll.offset;
  }

  void _onControllerChanged() {
    final String text = _controller.text;
    final TextSelection selection = _controller.selection;
    widget.store.edited(_tab, text, selection);
    if (identical(text, _lastText) || text == _lastText) return;
    _lastText = text;
    final EditorTextController controller = _controller;
    if (controller is MarkdownTextController) {
      controller.styled = !_tab.isLarge;
    }
    if (_find.visible) {
      _find.recompute(text, anchor: selection.isValid ? selection.start : 0);
    }
  }

  void _onFindChanged() {
    _controller.setMatches(
      _find.visible ? _find.highlights : const <TextRange>[],
      _find.visible ? _find.highlightedCurrent : -1,
    );
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Editing
  // ---------------------------------------------------------------------------

  void _apply(TextEditingValue value) {
    _controller.value = value.copyWith(composing: TextRange.empty);
    _focus.requestFocus();
  }

  void _inline(InlineMark mark) =>
      _apply(MarkdownCommands.toggleInline(_controller.value, mark));

  void _heading(int level) =>
      _apply(MarkdownCommands.setHeading(_controller.value, level));

  void _prefix(LinePrefix kind) =>
      _apply(MarkdownCommands.toggleLinePrefix(_controller.value, kind));

  void _codeBlock() =>
      _apply(MarkdownCommands.insertCodeBlock(_controller.value));

  void _link() => _apply(MarkdownCommands.insertLink(_controller.value));

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final TextEditingValue value = _controller.value;
    if (value.composing.isValid && !value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final bool outdent = keyboard.isShiftPressed;
    final TextEditingValue? result = widget.markdown
        ? MarkdownCommands.indent(value, outdent: outdent)
        : PlainTextCommands.indent(value, outdent: outdent);
    if (result != null) _apply(result);
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------------------
  // Find and replace
  // ---------------------------------------------------------------------------

  void _openFind({bool replace = false}) {
    final TextSelection selection = _controller.selection;
    String seed = '';
    if (selection.isValid && !selection.isCollapsed) {
      final String selected = _controller.text.substring(
        selection.start,
        selection.end,
      );
      if (!selected.contains('\n') && selected.length <= 200) seed = selected;
    }
    _find.show(replace: replace);
    _find.configure(
      query: seed.isEmpty ? _find.query : seed,
      text: _controller.text,
      anchor: selection.isValid ? selection.start : 0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _findFocus.requestFocus();
    });
  }

  void _closeFind() {
    _find.hide();
    _focus.requestFocus();
  }

  void _jump(TextRange match) {
    _controller.selection = TextSelection(
      baseOffset: match.start,
      extentOffset: match.end,
    );
    _reveal(match.start);
  }

  void _reveal(int offset) {
    final EditableTextState? state = findEditableTextState(
      _fieldKey.currentContext,
    );
    final int length = _controller.text.length;
    state?.bringIntoView(TextPosition(offset: offset.clamp(0, length)));
  }

  void _findNext() {
    if (!_find.visible) {
      _openFind();
      return;
    }
    final TextRange? match = _find.next();
    if (match != null) _jump(match);
  }

  void _findPrevious() {
    if (!_find.visible) {
      _openFind();
      return;
    }
    final TextRange? match = _find.previous();
    if (match != null) _jump(match);
  }

  void _replaceCurrent() {
    final ({String text, int caret})? result = _find.replaceCurrent(
      _controller.text,
    );
    if (result == null) return;
    _controller.value = TextEditingValue(
      text: result.text,
      selection: TextSelection.collapsed(offset: result.caret),
    );
    _find.recompute(result.text, anchor: result.caret);
    final TextRange? match = _find.currentMatch;
    if (match != null) _jump(match);
    // The Replace buttons disable themselves when nothing is left to replace,
    // which would drop the focus, so keep it in the find field.
    _findFocus.requestFocus();
  }

  void _replaceAll() {
    final String? replaced = _find.replaceAll(_controller.text);
    if (replaced == null) return;
    final int caret = _controller.selection.isValid
        ? _controller.selection.start.clamp(0, replaced.length)
        : 0;
    _controller.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: caret),
    );
    _find.recompute(replaced, anchor: caret);
    _findFocus.requestFocus();
  }

  // ---------------------------------------------------------------------------
  // Building
  // ---------------------------------------------------------------------------

  Map<ShortcutActivator, VoidCallback> _bindings(bool editable) {
    if (!editable) return const <ShortcutActivator, VoidCallback>{};
    SingleActivator mod(LogicalKeyboardKey key, {bool shift = false}) =>
        SingleActivator(
          key,
          control: !usesCommandKey,
          meta: usesCommandKey,
          shift: shift,
        );
    return <ShortcutActivator, VoidCallback>{
      mod(LogicalKeyboardKey.keyF): _openFind,
      // Cmd+H hides the app on macOS, so replace moves to Cmd+Option+F there.
      (usesCommandKey
          ? const SingleActivator(
              LogicalKeyboardKey.keyF,
              meta: true,
              alt: true,
            )
          : mod(LogicalKeyboardKey.keyH)): () =>
          _openFind(replace: true),
      const SingleActivator(LogicalKeyboardKey.f3): _findNext,
      const SingleActivator(LogicalKeyboardKey.f3, shift: true): _findPrevious,
      if (widget.markdown) ...<ShortcutActivator, VoidCallback>{
        mod(LogicalKeyboardKey.keyB): () => _inline(InlineMark.bold),
        mod(LogicalKeyboardKey.keyI): () => _inline(InlineMark.italic),
        mod(LogicalKeyboardKey.keyE): () => _inline(InlineMark.code),
        mod(LogicalKeyboardKey.keyX, shift: true): () =>
            _inline(InlineMark.strike),
        mod(LogicalKeyboardKey.keyK): _link,
        mod(LogicalKeyboardKey.digit0): () => _heading(0),
        mod(LogicalKeyboardKey.digit1): () => _heading(1),
        mod(LogicalKeyboardKey.digit2): () => _heading(2),
        mod(LogicalKeyboardKey.digit3): () => _heading(3),
        mod(LogicalKeyboardKey.digit4): () => _heading(4),
        mod(LogicalKeyboardKey.digit5): () => _heading(5),
        mod(LogicalKeyboardKey.digit6): () => _heading(6),
        mod(LogicalKeyboardKey.keyL, shift: true): () =>
            _prefix(LinePrefix.bullet),
        mod(LogicalKeyboardKey.keyO, shift: true): () =>
            _prefix(LinePrefix.numbered),
        mod(LogicalKeyboardKey.keyT, shift: true): () =>
            _prefix(LinePrefix.task),
        mod(LogicalKeyboardKey.keyQ, shift: true): () =>
            _prefix(LinePrefix.quote),
        mod(LogicalKeyboardKey.keyK, shift: true): _codeBlock,
      },
    };
  }

  TextStyle _textStyle(ThemeData theme) {
    final ColorScheme colors = theme.colorScheme;
    if (widget.markdown) {
      return (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
        fontSize: 15,
        height: 1.55,
        color: colors.onSurface,
      );
    }
    return TextStyle(
      fontFamily: editorMonospaceFamily,
      fontFamilyFallback: editorMonospaceFallback,
      fontSize: 13.5,
      height: 1.5,
      color: colors.onSurface,
    );
  }

  Widget _field(ThemeData theme) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      // One explicit scrollbar wraps the field (the platform's automatic one is
      // switched off so there are not two). Because it wraps the field's own
      // scrollable rather than sitting beside it, the wheel, touchpad and
      // thumb drag all scroll the text, including with the cursor over the bar.
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          controller: _scroll,
          child: TextField(
            key: _fieldKey,
            controller: _controller,
            focusNode: _focus,
            scrollController: _scroll,
            autofocus: widget.autofocus,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            keyboardType: TextInputType.multiline,
            style: _textStyle(theme),
            cursorColor: theme.colorScheme.primary,
            inputFormatters: _formatters,
            autocorrect: false,
            enableSuggestions: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            decoration: const InputDecoration(
              isCollapsed: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              // No padding on the right, so the field runs to the panel edge.
              contentPadding: EdgeInsets.fromLTRB(20, 16, 0, 16),
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview() => ListenableBuilder(
    listenable: _controller,
    builder: (BuildContext context, Widget? child) =>
        MarkdownPreview(text: _controller.text),
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final MarkdownViewMode mode = widget.markdown
        ? widget.viewMode
        : MarkdownViewMode.edit;
    final bool editable = mode != MarkdownViewMode.preview;

    final Widget pane = Stack(
      children: <Widget>[
        Positioned.fill(child: _field(theme)),
        if (_find.visible)
          Positioned(
            top: 8,
            right: 20,
            child: EditorFindBar(
              model: _find,
              queryFocus: _findFocus,
              textProvider: () => _controller.text,
              anchorProvider: () => _controller.selection.isValid
                  ? _controller.selection.start
                  : 0,
              onJump: _jump,
              onReplace: _replaceCurrent,
              onReplaceAll: _replaceAll,
              onClose: _closeFind,
            ),
          ),
      ],
    );
    final Widget body = switch (mode) {
      MarkdownViewMode.edit => pane,
      MarkdownViewMode.preview => _preview(),
      MarkdownViewMode.split => Row(
        children: <Widget>[
          Expanded(child: pane),
          VerticalDivider(width: 1, color: colors.outlineVariant),
          Expanded(child: _preview()),
        ],
      ),
    };

    return CallbackShortcuts(
      bindings: _bindings(editable),
      child: Column(
        children: <Widget>[
          if (widget.markdown)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: SizedBox(
                width: double.infinity,
                child: MarkdownRibbon(
                  mode: mode,
                  onModeChanged: (MarkdownViewMode next) =>
                      widget.onViewModeChanged?.call(next),
                  onInline: _inline,
                  onHeading: _heading,
                  onPrefix: _prefix,
                  onCodeBlock: _codeBlock,
                  onLink: _link,
                  onFind: _openFind,
                ),
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
