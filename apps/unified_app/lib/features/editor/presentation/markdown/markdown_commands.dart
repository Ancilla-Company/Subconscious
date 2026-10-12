import 'package:flutter/services.dart';

/// Inline markdown formats that wrap the selection.
enum InlineMark {
  bold('**'),
  italic('*'),
  strike('~~'),
  code('`');

  const InlineMark(this.token);

  /// The characters placed on each side of the text.
  final String token;
}

/// The kinds of line prefix the editor can toggle.
enum LinePrefix { bullet, numbered, task, quote }

/// Markdown editing commands over a [TextEditingValue].
///
/// Every command returns the new value and leaves the controller alone, so the
/// ribbon, the keyboard shortcuts and the tests all drive the same code. The
/// edits only touch the lines or characters they are asked about, so the rest
/// of the document keeps its exact bytes.
abstract final class MarkdownCommands {
  // ---------------------------------------------------------------------------
  // Inline formats
  // ---------------------------------------------------------------------------

  /// Wraps the selection in [mark], or removes the wrapper when it is already
  /// there. With no selection the word at the caret is used.
  static TextEditingValue toggleInline(
    TextEditingValue value,
    InlineMark mark,
  ) {
    final String text = value.text;
    final TextRange range = _selectionRange(value);
    int start = range.start;
    int end = range.end;
    if (start == end) {
      final TextRange? word = _wordAt(text, start);
      if (word != null) {
        start = word.start;
        end = word.end;
      }
    } else {
      // Whitespace next to a marker stops it from being recognised.
      while (start < end && _isBlank(text.codeUnitAt(start))) {
        start++;
      }
      while (end > start && _isBlank(text.codeUnitAt(end - 1))) {
        end--;
      }
    }

    final String token = mark.token;
    final int length = token.length;
    final int unit = token.codeUnitAt(0);

    // Markers just outside the text, as in **word**.
    int before = 0;
    while (start - before - 1 >= 0 && text.codeUnitAt(start - before - 1) == unit) {
      before++;
    }
    int after = 0;
    while (end + after < text.length && text.codeUnitAt(end + after) == unit) {
      after++;
    }
    final int outside = before < after ? before : after;
    if (start < end && _hasMark(outside, mark)) {
      final String result =
          text.substring(0, start - length) +
          text.substring(start, end) +
          text.substring(end + length);
      return TextEditingValue(
        text: result,
        selection: TextSelection(
          baseOffset: start - length,
          extentOffset: end - length,
        ),
      );
    }

    // Markers inside the selection, as when the whole **word** is selected.
    if (start < end) {
      int lead = 0;
      while (start + lead < end && text.codeUnitAt(start + lead) == unit) {
        lead++;
      }
      int trail = 0;
      while (end - trail - 1 >= start && text.codeUnitAt(end - trail - 1) == unit) {
        trail++;
      }
      final int inside = lead < trail ? lead : trail;
      if (inside * 2 < end - start && _hasMark(inside, mark)) {
        final String result =
            text.substring(0, start) +
            text.substring(start + length, end - length) +
            text.substring(end);
        return TextEditingValue(
          text: result,
          selection: TextSelection(
            baseOffset: start,
            extentOffset: end - 2 * length,
          ),
        );
      }
    }

    final String result =
        text.substring(0, start) +
        token +
        text.substring(start, end) +
        token +
        text.substring(end);
    return TextEditingValue(
      text: result,
      selection: TextSelection(
        baseOffset: start + length,
        extentOffset: end + length,
      ),
    );
  }

  /// Whether a run of [count] marker characters around text includes [mark].
  static bool _hasMark(int count, InlineMark mark) => switch (mark) {
    // One star is italic, two are bold, three are both.
    InlineMark.italic => count.isOdd,
    InlineMark.bold => count >= 2,
    InlineMark.strike => count >= 2,
    InlineMark.code => count >= 1,
  };

  // ---------------------------------------------------------------------------
  // Headings and line prefixes
  // ---------------------------------------------------------------------------

  static final RegExp _headingPrefix = RegExp(r'^( {0,3})(#{1,6})([ \t]+|$)');
  static final RegExp _taskPrefix = RegExp(r'^(\s*)[-*+][ \t]+\[[ xX]\][ \t]+');
  static final RegExp _bulletPrefix = RegExp(r'^(\s*)[-*+][ \t]+');
  static final RegExp _numberedPrefix = RegExp(r'^(\s*)\d{1,9}[.)][ \t]+');
  static final RegExp _quotePrefix = RegExp(r'^(\s*)>[ \t]?');

  /// Sets the heading level of the selected lines. A level of 0, or the level
  /// the lines already have, turns the heading off.
  static TextEditingValue setHeading(TextEditingValue value, int level) {
    return _mapLines(value, (List<String> lines) {
      final List<int> current = <int>[
        for (final String line in lines)
          if (line.trim().isNotEmpty) _headingLevel(line),
      ];
      final bool allHaveLevel =
          level > 0 && current.isNotEmpty && current.every((int c) => c == level);
      final bool remove = level == 0 || allHaveLevel;
      return <String>[
        for (final String line in lines)
          if (line.trim().isEmpty && lines.length > 1)
            line
          else
            _withHeading(line, remove ? 0 : level),
      ];
    });
  }

  static int _headingLevel(String line) {
    final RegExpMatch? match = _headingPrefix.firstMatch(line);
    return match == null ? 0 : match.group(2)!.length;
  }

  static String _withHeading(String line, int level) {
    final String stripped = line.replaceFirst(_headingPrefix, '');
    return level == 0 ? stripped : '${'#' * level} $stripped';
  }

  /// Adds the prefix to the selected lines, or removes it when every line
  /// already has it. Switching between list kinds replaces the old marker.
  static TextEditingValue toggleLinePrefix(
    TextEditingValue value,
    LinePrefix kind,
  ) {
    return _mapLines(value, (List<String> lines) {
      final Iterable<String> content = lines.where(
        (String line) => line.trim().isNotEmpty,
      );
      final bool allHave =
          content.isNotEmpty &&
          content.every((String line) => _prefixKind(line) == kind);
      int number = 1;
      return <String>[
        for (final String line in lines)
          if (line.trim().isEmpty && lines.length > 1)
            line
          else
            _withPrefix(line, allHave ? null : kind, allHave ? 0 : number++),
      ];
    });
  }

  static LinePrefix? _prefixKind(String line) {
    if (_taskPrefix.hasMatch(line)) return LinePrefix.task;
    if (_bulletPrefix.hasMatch(line)) return LinePrefix.bullet;
    if (_numberedPrefix.hasMatch(line)) return LinePrefix.numbered;
    if (_quotePrefix.hasMatch(line)) return LinePrefix.quote;
    return null;
  }

  static String _withPrefix(String line, LinePrefix? kind, int number) {
    final LinePrefix? existing = _prefixKind(line);
    String indent = '';
    String body = line;
    if (existing != null) {
      final RegExp pattern = switch (existing) {
        LinePrefix.task => _taskPrefix,
        LinePrefix.bullet => _bulletPrefix,
        LinePrefix.numbered => _numberedPrefix,
        LinePrefix.quote => _quotePrefix,
      };
      final RegExpMatch match = pattern.firstMatch(line)!;
      indent = match.group(1)!;
      body = line.substring(match.end);
    } else {
      final RegExpMatch? lead = RegExp(r'^\s*').firstMatch(line);
      indent = lead?.group(0) ?? '';
      body = line.substring(indent.length);
    }
    if (kind == null) return '$indent$body';
    final String marker = switch (kind) {
      LinePrefix.bullet => '- ',
      LinePrefix.numbered => '$number. ',
      LinePrefix.task => '- [ ] ',
      LinePrefix.quote => '> ',
    };
    return '$indent$marker$body';
  }

  /// Wraps the selected lines in a fenced code block, or inserts an empty one.
  static TextEditingValue insertCodeBlock(TextEditingValue value) {
    final String text = value.text;
    final TextRange range = _selectionRange(value);
    final int firstStart = _lineStart(text, range.start);
    int lastEnd = _lineEnd(text, range.end);
    if (range.end > range.start && text.codeUnitAt(range.end - 1) == 0x0A) {
      lastEnd = _lineEnd(text, range.end - 1);
    }
    if (range.start == range.end) {
      final bool atLineStart = range.start == firstStart;
      final String prefix = atLineStart ? '' : '\n';
      final String inserted = '$prefix```\n\n```';
      final String result =
          text.substring(0, range.start) + inserted + text.substring(range.end);
      final int caret = range.start + prefix.length + 4;
      return TextEditingValue(
        text: result,
        selection: TextSelection.collapsed(offset: caret),
      );
    }
    final String block = text.substring(firstStart, lastEnd);
    final String wrapped = '```\n$block\n```';
    return TextEditingValue(
      text: text.substring(0, firstStart) + wrapped + text.substring(lastEnd),
      selection: TextSelection(
        baseOffset: firstStart + 4,
        extentOffset: firstStart + 4 + block.length,
      ),
    );
  }

  /// Turns the selection into a link, leaving the address ready to type.
  static TextEditingValue insertLink(TextEditingValue value) {
    final String text = value.text;
    final TextRange range = _selectionRange(value);
    final String selected = text.substring(range.start, range.end);
    final String before = text.substring(0, range.start);
    final String after = text.substring(range.end);
    if (RegExp(r'^https?://\S+$').hasMatch(selected)) {
      return TextEditingValue(
        text: '$before[]($selected)$after',
        selection: TextSelection.collapsed(offset: range.start + 1),
      );
    }
    final String label = selected;
    final String result = '$before[$label](url)$after';
    final int urlStart = range.start + label.length + 3;
    return TextEditingValue(
      text: result,
      selection: label.isEmpty
          ? TextSelection.collapsed(offset: range.start + 1)
          : TextSelection(baseOffset: urlStart, extentOffset: urlStart + 3),
    );
  }

  // ---------------------------------------------------------------------------
  // Indentation
  // ---------------------------------------------------------------------------

  /// Indents or outdents for the Tab key. Returns null when there is nothing
  /// to do, so the key press is still consumed.
  static TextEditingValue? indent(
    TextEditingValue value, {
    required bool outdent,
  }) {
    final String text = value.text;
    final TextRange range = _selectionRange(value);
    final int firstStart = _lineStart(text, range.start);
    final bool multiline = text.substring(range.start, range.end).contains('\n');
    final String firstLine = text.substring(
      firstStart,
      _lineEnd(text, range.start),
    );
    final bool onListItem = _prefixKind(firstLine) != null;
    if (!outdent && !multiline && !onListItem && range.start == range.end) {
      return value.copyWith(
        text: '${text.substring(0, range.start)}  ${text.substring(range.end)}',
        selection: TextSelection.collapsed(offset: range.start + 2),
      );
    }
    final int unit = _indentWidth(firstLine);
    return _mapLines(value, (List<String> lines) {
      return <String>[
        for (final String line in lines)
          if (line.trim().isEmpty && lines.length > 1)
            line
          else if (outdent)
            _outdentLine(line, unit)
          else
            '${' ' * unit}$line',
      ];
    });
  }

  static int _indentWidth(String line) {
    final RegExpMatch? numbered = _numberedPrefix.firstMatch(line);
    if (numbered != null) {
      return (line.length - line.replaceFirst(_numberedPrefix, '').length) -
          numbered.group(1)!.length;
    }
    return 2;
  }

  static String _outdentLine(String line, int width) {
    if (line.startsWith('\t')) return line.substring(1);
    int removed = 0;
    while (removed < width &&
        removed < line.length &&
        line.codeUnitAt(removed) == 0x20) {
      removed++;
    }
    return line.substring(removed);
  }

  // ---------------------------------------------------------------------------
  // Line mapping
  // ---------------------------------------------------------------------------

  /// Applies [transform] to the lines the selection touches and keeps the
  /// selection on the same text.
  static TextEditingValue _mapLines(
    TextEditingValue value,
    List<String> Function(List<String> lines) transform,
  ) {
    final String text = value.text;
    final TextRange range = _selectionRange(value);
    final int blockStart = _lineStart(text, range.start);
    int effectiveEnd = range.end;
    if (range.end > range.start && text.codeUnitAt(range.end - 1) == 0x0A) {
      effectiveEnd = range.end - 1;
    }
    final int blockEnd = _lineEnd(text, effectiveEnd);
    final List<String> lines = text.substring(blockStart, blockEnd).split('\n');
    final List<String> mapped = transform(lines);

    final String replacement = mapped.join('\n');
    final String result =
        text.substring(0, blockStart) + replacement + text.substring(blockEnd);

    int shift(int offset) {
      if (offset < blockStart) return offset;
      if (offset >= blockEnd) return offset + replacement.length - (blockEnd - blockStart);
      // Inside the block: keep the same position within the same line.
      int consumed = blockStart;
      int produced = blockStart;
      for (int index = 0; index < lines.length; index++) {
        final int lineEnd = consumed + lines[index].length;
        if (offset <= lineEnd) {
          final int column = offset - consumed;
          final String before = lines[index];
          final String after = mapped[index];
          // Every command changes only the start of a line, so the caret keeps
          // its place in the text by moving with the length difference.
          final int adjusted = column + (after.length - before.length);
          return produced + adjusted.clamp(0, after.length);
        }
        consumed = lineEnd + 1;
        produced += mapped[index].length + 1;
      }
      return offset;
    }

    if (range.start == range.end) {
      return TextEditingValue(
        text: result,
        selection: TextSelection.collapsed(offset: shift(range.start)),
      );
    }
    return TextEditingValue(
      text: result,
      selection: TextSelection(
        baseOffset: blockStart,
        extentOffset: blockStart + replacement.length,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Text helpers
  // ---------------------------------------------------------------------------

  static TextRange _selectionRange(TextEditingValue value) {
    final TextSelection selection = value.selection;
    final int length = value.text.length;
    if (!selection.isValid) return TextRange.collapsed(length);
    final int start = selection.start.clamp(0, length);
    final int end = selection.end.clamp(0, length);
    return TextRange(start: start, end: end);
  }

  static int _lineStart(String text, int offset) =>
      offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

  static int _lineEnd(String text, int offset) {
    final int index = text.indexOf('\n', offset);
    return index < 0 ? text.length : index;
  }

  static bool _isBlank(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;

  static bool _isWordUnit(int unit) =>
      (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A) ||
      unit == 0x5F ||
      unit > 0x7F;

  static TextRange? _wordAt(String text, int offset) {
    int start = offset;
    int end = offset;
    while (start > 0 && _isWordUnit(text.codeUnitAt(start - 1))) {
      start--;
    }
    while (end < text.length && _isWordUnit(text.codeUnitAt(end))) {
      end++;
    }
    return start == end ? null : TextRange(start: start, end: end);
  }
}

/// Keeps pasted `\r\n` and lone `\r` out of a text field.
///
/// A text field works with `\n` only. Windows clipboards carry `\r\n`, which
/// would otherwise mix two styles into the document.
final class NormalizeNewlinesFormatter extends TextInputFormatter {
  const NormalizeNewlinesFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String text = newValue.text;
    if (!text.contains('\r')) return newValue;
    int removedBefore(int offset) {
      int removed = 0;
      final int limit = offset.clamp(0, text.length);
      for (int index = 0; index < limit; index++) {
        if (text.codeUnitAt(index) == 0x0D &&
            index + 1 < text.length &&
            text.codeUnitAt(index + 1) == 0x0A) {
          removed++;
        }
      }
      return removed;
    }

    TextSelection selection = newValue.selection;
    if (selection.isValid) {
      selection = TextSelection(
        baseOffset: selection.baseOffset - removedBefore(selection.baseOffset),
        extentOffset:
            selection.extentOffset - removedBefore(selection.extentOffset),
        affinity: selection.affinity,
        isDirectional: selection.isDirectional,
      );
    }
    TextRange composing = newValue.composing;
    if (composing.isValid) {
      composing = TextRange(
        start: composing.start - removedBefore(composing.start),
        end: composing.end - removedBefore(composing.end),
      );
    }
    return TextEditingValue(
      text: text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
      selection: selection,
      composing: composing,
    );
  }
}

/// Continues lists and quotes when Enter is pressed, and leaves them when
/// Enter is pressed on an empty item.
final class MarkdownEnterFormatter extends TextInputFormatter {
  const MarkdownEnterFormatter();

  static final RegExp _task = RegExp(r'^(\s*)([-*+])([ \t]+)\[[ xX]\]([ \t]+)');
  static final RegExp _bullet = RegExp(r'^(\s*)([-*+])([ \t]+)');
  static final RegExp _numbered = RegExp(r'^(\s*)(\d{1,9})([.)])([ \t]+)');
  static final RegExp _quote = RegExp(r'^((?:\s*>[ \t]?)+)');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String text = newValue.text;
    final TextSelection selection = newValue.selection;
    if (text.length != oldValue.text.length + 1 ||
        !selection.isValid ||
        !selection.isCollapsed) {
      return newValue;
    }
    final int caret = selection.baseOffset;
    if (caret < 1 || text.codeUnitAt(caret - 1) != 0x0A) return newValue;
    // Only a single newline typed at the caret counts; a paste of text that
    // happens to end in a newline would have changed more than one character.
    if (!oldValue.text.startsWith(text.substring(0, caret - 1)) ||
        !oldValue.text.endsWith(text.substring(caret))) {
      return newValue;
    }
    final int lineStart = caret < 2 ? 0 : text.lastIndexOf('\n', caret - 2) + 1;
    final String previous = text.substring(lineStart, caret - 1);
    if (_insideFence(text, caret - 1)) {
      return _keepIndent(newValue, previous, caret);
    }

    final RegExpMatch? task = _task.firstMatch(previous);
    if (task != null) {
      final String rest = previous.substring(task.end);
      if (rest.trim().isEmpty) return _leave(newValue, lineStart, caret);
      return _insert(
        newValue,
        caret,
        '${task.group(1)}${task.group(2)}${task.group(3)}[ ]${task.group(4)}',
      );
    }
    final RegExpMatch? bullet = _bullet.firstMatch(previous);
    if (bullet != null && !_isRuleLine(previous)) {
      final String rest = previous.substring(bullet.end);
      if (rest.trim().isEmpty) return _leave(newValue, lineStart, caret);
      return _insert(
        newValue,
        caret,
        '${bullet.group(1)}${bullet.group(2)}${bullet.group(3)}',
      );
    }
    final RegExpMatch? numbered = _numbered.firstMatch(previous);
    if (numbered != null) {
      final String rest = previous.substring(numbered.end);
      if (rest.trim().isEmpty) return _leave(newValue, lineStart, caret);
      final int next = int.parse(numbered.group(2)!) + 1;
      return _insert(
        newValue,
        caret,
        '${numbered.group(1)}$next${numbered.group(3)}${numbered.group(4)}',
      );
    }
    final RegExpMatch? quote = _quote.firstMatch(previous);
    if (quote != null) {
      final String rest = previous.substring(quote.end);
      if (rest.trim().isEmpty) return _leave(newValue, lineStart, caret);
      return _insert(newValue, caret, quote.group(1)!);
    }
    return _keepIndent(newValue, previous, caret);
  }

  static bool _isRuleLine(String line) =>
      RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$').hasMatch(line);

  /// Whether [offset] falls inside a fenced code block.
  static bool _insideFence(String text, int offset) {
    bool inside = false;
    int? unit;
    int length = 0;
    int cursor = 0;
    while (cursor < offset) {
      final int newline = text.indexOf('\n', cursor);
      final int end = newline < 0 || newline > offset ? offset : newline;
      final String line = text.substring(cursor, end).trimLeft();
      if (line.startsWith('```') || line.startsWith('~~~')) {
        final int fenceUnit = line.codeUnitAt(0);
        int run = 0;
        while (run < line.length && line.codeUnitAt(run) == fenceUnit) {
          run++;
        }
        if (!inside) {
          inside = true;
          unit = fenceUnit;
          length = run;
        } else if (fenceUnit == unit && run >= length && line.substring(run).trim().isEmpty) {
          inside = false;
        }
      }
      if (newline < 0 || newline >= offset) break;
      cursor = newline + 1;
    }
    return inside;
  }

  static TextEditingValue _insert(
    TextEditingValue value,
    int caret,
    String prefix,
  ) => TextEditingValue(
    text: value.text.substring(0, caret) + prefix + value.text.substring(caret),
    selection: TextSelection.collapsed(offset: caret + prefix.length),
  );

  /// Removes the empty item's marker and the newline just typed, leaving the
  /// caret on a blank line.
  static TextEditingValue _leave(
    TextEditingValue value,
    int lineStart,
    int caret,
  ) => TextEditingValue(
    text: value.text.substring(0, lineStart) + value.text.substring(caret),
    selection: TextSelection.collapsed(offset: lineStart),
  );

  static TextEditingValue _keepIndent(
    TextEditingValue value,
    String previous,
    int caret,
  ) {
    final RegExpMatch? lead = RegExp(r'^[ \t]+').firstMatch(previous);
    if (lead == null) return value;
    return _insert(value, caret, lead.group(0)!);
  }
}

/// Editing commands for plain text, where Tab inserts a real tab character.
abstract final class PlainTextCommands {
  /// Indents or outdents for the Tab key.
  ///
  /// With a caret or a one-line selection, Tab replaces the selection with a
  /// tab character. When the selection covers several lines, each line gets a
  /// leading tab. Shift+Tab removes one leading tab, or up to four spaces.
  static TextEditingValue indent(
    TextEditingValue value, {
    required bool outdent,
  }) {
    final String text = value.text;
    final TextSelection selection = value.selection;
    final int length = text.length;
    final int start = selection.isValid ? selection.start.clamp(0, length) : length;
    final int end = selection.isValid ? selection.end.clamp(0, length) : length;
    final bool multiline = text.substring(start, end).contains('\n');
    if (!outdent && !multiline) {
      return TextEditingValue(
        text: '${text.substring(0, start)}\t${text.substring(end)}',
        selection: TextSelection.collapsed(offset: start + 1),
      );
    }
    final int blockStart = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    int effectiveEnd = end;
    if (end > start && text.codeUnitAt(end - 1) == 0x0A) effectiveEnd = end - 1;
    final int newline = text.indexOf('\n', effectiveEnd);
    final int blockEnd = newline < 0 ? length : newline;
    final List<String> lines = text.substring(blockStart, blockEnd).split('\n');
    final List<String> mapped = <String>[
      for (final String line in lines)
        if (outdent) _outdent(line) else if (line.isEmpty) line else '\t$line',
    ];
    final String replacement = mapped.join('\n');
    final String result =
        text.substring(0, blockStart) + replacement + text.substring(blockEnd);
    if (start == end) {
      final int delta = mapped.first.length - lines.first.length;
      final int caret = (start + delta).clamp(blockStart, blockStart + mapped.first.length);
      return TextEditingValue(
        text: result,
        selection: TextSelection.collapsed(offset: caret),
      );
    }
    return TextEditingValue(
      text: result,
      selection: TextSelection(
        baseOffset: blockStart,
        extentOffset: blockStart + replacement.length,
      ),
    );
  }

  static String _outdent(String line) {
    if (line.startsWith('\t')) return line.substring(1);
    int removed = 0;
    while (removed < 4 &&
        removed < line.length &&
        line.codeUnitAt(removed) == 0x20) {
      removed++;
    }
    return line.substring(removed);
  }
}
