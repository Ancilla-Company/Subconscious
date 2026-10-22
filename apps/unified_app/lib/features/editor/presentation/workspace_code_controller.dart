import 'package:flutter/material.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';

import 'indent_style.dart';
import 'tab_display.dart';

/// Starts a new line at the indentation of the line above, one level deeper
/// after an opening bracket or a trailing colon.
///
/// The package's own version counts spaces only, so it drops the indentation
/// of any line indented with tabs.
final class CopyIndentModifier extends CodeModifier {
  const CopyIndentModifier(this.indent) : super('\n');

  final IndentStyle indent;

  @override
  TextEditingValue? updateString(
    String text,
    TextSelection sel,
    EditorParams params,
  ) {
    final int caret = sel.start.clamp(0, text.length);
    final int lineStart = caret == 0
        ? 0
        : text.lastIndexOf('\n', caret - 1) + 1;
    int end = lineStart;
    while (end < caret &&
        (text.codeUnitAt(end) == 0x20 || text.codeUnitAt(end) == 0x09)) {
      end++;
    }
    String leading = text.substring(lineStart, end);
    final String before = text.substring(lineStart, caret).trimRight();
    if (before.isNotEmpty) {
      final String last = before[before.length - 1];
      if (last == '{' || last == '[' || last == '(' || last == ':') {
        leading += indent.unit;
      }
    }
    return replace(text, sel.start, sel.end, '\n$leading');
  }
}

/// The code editor's controller, adjusted so that it never changes text the
/// user did not type.
///
/// It keeps tabs as tabs, indents with the file's own habit, and turns Tab on
/// a selection into an indent. The package's default replaces the selected
/// text with spaces, which silently deletes it.
final class WorkspaceCodeController extends CodeController {
  WorkspaceCodeController({
    required String text,
    required super.language,
    required this.indent,
  }) : super(
         text: text,
         // The package also offers modifiers that close brackets and quotes
         // and pull a closing brace back a level. They are left out: the
         // first inserts text nobody typed, and the second edits text before
         // the caret, which the package's own edit tracking mishandles.
         modifiers: <CodeModifier>[CopyIndentModifier(indent)],
         params: EditorParams(tabSpaces: indent.width),
       );

  final IndentStyle indent;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    bool? withComposing,
  }) {
    final TextSpan span = super.buildTextSpan(
      context: context,
      style: style,
      withComposing: withComposing,
    );
    // The text is checked first so the common tab-free file pays nothing.
    if (!text.contains('\t')) return span;
    return TabDisplay.expand(span, style ?? const TextStyle());
  }

  @override
  void onTabKeyAction() {
    if (popupController.shouldShow) {
      super.onTabKeyAction();
      return;
    }
    if (!selection.isValid) return;
    final bool multiline =
        !selection.isCollapsed &&
        text.substring(selection.start, selection.end).contains('\n');
    if (multiline || (selection.isCollapsed && !indent.useTabs)) {
      indentSelection();
      return;
    }
    insertStr(indent.unit);
  }

  @override
  void indentSelection() {
    if (!selection.isValid) return;
    if (!indent.useTabs) {
      super.indentSelection();
      return;
    }
    if (selection.isCollapsed) {
      insertStr('\t');
      return;
    }
    modifySelectedLines((String line) => line == '\n' ? line : '\t$line');
  }

  @override
  void outdentSelection() {
    if (!selection.isValid) return;
    modifySelectedLines((String line) {
      if (line == '\n') return line;
      if (line.startsWith('\t')) return line.substring(1);
      int spaces = 0;
      while (spaces < indent.width &&
          spaces < line.length &&
          line.codeUnitAt(spaces) == 0x20) {
        spaces++;
      }
      return line.substring(spaces);
    });
  }
}
