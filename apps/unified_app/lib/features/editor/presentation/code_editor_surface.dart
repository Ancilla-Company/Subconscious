import 'package:flutter/material.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';

import '../controller/editor_document_store.dart';
import '../controller/editor_tab.dart';
import 'editor_fonts.dart';
import 'indent_style.dart';
import 'language_modes.dart';
import 'workspace_code_controller.dart';

/// A syntax-highlighting editor for source code.
///
/// It is built on the code editor package with a controller that only acts on
/// what the user types. The package's own tab handling rewrites every tab in a
/// file as spaces the moment it opens, and its Tab key replaces a selection
/// with spaces; neither is acceptable for a file the user only wants to edit.
final class CodeEditorSurface extends StatefulWidget {
  const CodeEditorSurface({
    required this.store,
    required this.tab,
    this.autofocus = false,
    super.key,
  });

  /// Above this size highlighting is skipped. The editor measures the whole
  /// file on every change, which stops being usable for very large files.
  static const int highlightLimitChars = 150000;

  final EditorDocumentStore store;
  final TextTab tab;
  final bool autofocus;

  @override
  State<CodeEditorSurface> createState() => _CodeEditorSurfaceState();
}

final class _CodeEditorSurfaceState extends State<CodeEditorSurface> {
  late final WorkspaceCodeController _controller;
  final FocusNode _focus = FocusNode(debugLabel: 'code editor');

  @override
  void initState() {
    super.initState();
    final TextTab tab = widget.tab;
    _controller = WorkspaceCodeController(
      text: tab.text,
      language: languageForPath(tab.path),
      indent: IndentStyle.detect(tab.text, path: tab.path),
    );
    final int length = _controller.text.length;
    if (tab.selection.isValid) {
      _controller.selection = TextSelection(
        baseOffset: tab.selection.baseOffset.clamp(0, length),
        extentOffset: tab.selection.extentOffset.clamp(0, length),
      );
    }
    _controller.addListener(_onControllerChanged);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    if (_controller.selection.isValid) {
      widget.tab.selection = _controller.selection;
    }
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    // Folded blocks are hidden from the visible text, so the full text is the
    // one that belongs in the file.
    widget.store.edited(widget.tab, _controller.fullText, _controller.selection);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    return CodeTheme(
      data: CodeThemeData(styles: dark ? monokaiSublimeTheme : githubTheme),
      child: Theme(
        data: theme.copyWith(
          inputDecorationTheme: const InputDecorationTheme(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            filled: false,
          ),
        ),
        // The panel around the editor already has a scrollbar.
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: CodeField(
            controller: _controller,
            focusNode: _focus,
            expands: true,
            decoration: const BoxDecoration(color: Colors.transparent),
            padding: EdgeInsets.zero,
            textStyle: TextStyle(
              fontFamily: editorMonospaceFamily,
              fontFamilyFallback: editorMonospaceFallback,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ),
      ),
    );
  }
}
