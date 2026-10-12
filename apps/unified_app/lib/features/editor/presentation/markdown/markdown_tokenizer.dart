import 'dart:typed_data';

/// Style bits attached to a stretch of markdown source.
///
/// The low three bits hold the heading level (0 for none); the rest are
/// independent flags that combine, so `**_both_**` is bold and italic at once.
abstract final class MdFlag {
  static const int headingMask = 7;
  static const int bold = 1 << 3;
  static const int italic = 1 << 4;
  static const int strike = 1 << 5;

  /// Inline code.
  static const int code = 1 << 6;

  /// The visible text of a link or image.
  static const int link = 1 << 7;

  /// Syntax characters such as `**`, `#`, backticks and brackets.
  static const int marker = 1 << 8;
  static const int quote = 1 << 9;

  /// A fenced code block, including its fences.
  static const int codeBlock = 1 << 10;

  /// List bullets, numbers and task checkboxes.
  static const int listMarker = 1 << 11;
  static const int rule = 1 << 12;

  /// A link destination.
  static const int url = 1 << 13;
  static const int tablePipe = 1 << 14;

  /// Inline HTML, which the preview does not render.
  static const int html = 1 << 15;
}

/// A stretch of the source `[start, end)` that shares one style.
final class MdRun {
  const MdRun(this.start, this.end, this.flags);

  final int start;
  final int end;
  final int flags;

  @override
  String toString() => 'MdRun($start, $end, ${flags.toRadixString(2)})';
}

/// Splits markdown [text] into styled runs that cover it completely.
///
/// This is meant for live styling while typing, so it favours speed and
/// stable behaviour on half-typed input over full CommonMark conformance. The
/// rendered preview, which uses a real parser, is the reference. Emphasis does
/// not span lines.
List<MdRun> tokenizeMarkdown(String text) => _Tokenizer(text).run();

final class _Fence {
  const _Fence(this.unit, this.length, {required this.quoted});

  final int unit;
  final int length;

  /// Whether the fence opened inside a block quote, so each of its lines
  /// starts with `>`.
  final bool quoted;
}

const int _space = 0x20;
const int _tab = 0x09;
const int _backtick = 0x60;
const int _tilde = 0x7E;
const int _star = 0x2A;
const int _underscore = 0x5F;
const int _dash = 0x2D;
const int _plus = 0x2B;
const int _hash = 0x23;
const int _gt = 0x3E;
const int _lt = 0x3C;
const int _lbracket = 0x5B;
const int _rbracket = 0x5D;
const int _lparen = 0x28;
const int _rparen = 0x29;
const int _backslash = 0x5C;
const int _bang = 0x21;
const int _pipe = 0x7C;
const int _colon = 0x3A;

bool _isSpace(int unit) => unit == _space || unit == _tab;

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

bool _isAsciiPunctuation(int unit) =>
    (unit >= 0x21 && unit <= 0x2F) ||
    (unit >= 0x3A && unit <= 0x40) ||
    (unit >= 0x5B && unit <= 0x60) ||
    (unit >= 0x7B && unit <= 0x7E);

bool _isWhitespace(int unit) =>
    unit == _space ||
    unit == _tab ||
    unit == 0x0A ||
    unit == 0x0D ||
    unit == 0xA0 ||
    unit == 0x3000 ||
    (unit >= 0x2000 && unit <= 0x200A);

/// Whether [unit] counts as punctuation when deciding if a `*` or `_` can
/// open or close emphasis.
bool _isPunctuation(int unit) =>
    _isAsciiPunctuation(unit) ||
    (unit >= 0x2010 && unit <= 0x2027) ||
    (unit >= 0x3001 && unit <= 0x3003) ||
    unit == 0x00A1 ||
    unit == 0x00BF ||
    unit == 0x00AB ||
    unit == 0x00BB;

final class _Delimiter {
  _Delimiter({
    required this.position,
    required this.unit,
    required this.count,
    required this.canOpen,
    required this.canClose,
  });

  /// Index of the first remaining delimiter character.
  int position;
  final int unit;
  int count;
  final bool canOpen;
  final bool canClose;
}

final class _Tokenizer {
  _Tokenizer(this.text);

  final String text;
  final List<MdRun> _runs = <MdRun>[];
  int _cursor = 0;
  _Fence? _fence;
  bool _inTable = false;

  List<MdRun> run() {
    int position = 0;
    final int length = text.length;
    while (position < length) {
      final int newline = text.indexOf('\n', position);
      final int next = newline < 0 ? length : newline + 1;
      int end = newline < 0 ? length : newline;
      if (end > position && text.codeUnitAt(end - 1) == 0x0D) end--;
      _line(position, end);
      position = next;
    }
    if (_cursor < length) _push(_cursor, length, 0);
    return _runs;
  }

  void _push(int start, int end, int flags) {
    if (end <= start) return;
    if (_runs.isNotEmpty) {
      final MdRun last = _runs.last;
      if (last.flags == flags && last.end == start) {
        _runs[_runs.length - 1] = MdRun(last.start, end, flags);
        _cursor = end;
        return;
      }
    }
    _runs.add(MdRun(start, end, flags));
    _cursor = end;
  }

  /// Adds a run, filling any gap since the previous one with plain text.
  void _emit(int start, int end, int flags) {
    if (end <= start) return;
    if (start > _cursor) _push(_cursor, start, 0);
    _push(start, end, flags);
  }

  void _line(int start, int end) {
    final _Fence? fence = _fence;
    if (fence != null) {
      _fenceLine(start, end, fence);
      return;
    }
    int position = start;
    int base = 0;
    while (true) {
      int cursor = position;
      int spaces = 0;
      while (cursor < end && text.codeUnitAt(cursor) == _space && spaces < 3) {
        cursor++;
        spaces++;
      }
      if (cursor < end && text.codeUnitAt(cursor) == _gt) {
        cursor++;
        if (cursor < end && text.codeUnitAt(cursor) == _space) cursor++;
        _emit(position, cursor, MdFlag.marker | MdFlag.quote);
        base |= MdFlag.quote;
        position = cursor;
      } else {
        break;
      }
    }
    if (position >= end) {
      _inTable = false;
      return;
    }

    final _Fence? opened = _fenceOpening(position, end, base);
    if (opened != null) {
      _fence = opened;
      _emit(position, end, base | MdFlag.codeBlock | MdFlag.marker);
      return;
    }
    if (_heading(position, end, base)) {
      _inTable = false;
      return;
    }
    if (_isRule(position, end)) {
      _emit(position, end, base | MdFlag.rule | MdFlag.marker);
      _inTable = false;
      return;
    }
    if (_listItem(position, end, base)) {
      _inTable = false;
      return;
    }
    if (_isTableDelimiter(position, end)) {
      _emit(position, end, base | MdFlag.marker | MdFlag.tablePipe);
      _inTable = true;
      return;
    }
    final bool tableRow = _isTableRow(position, end);
    _inline(position, end, base, tableRow: tableRow);
    _inTable = tableRow;
  }

  // ---------------------------------------------------------------------------
  // Block structure
  // ---------------------------------------------------------------------------

  _Fence? _fenceOpening(int start, int end, int base) {
    int cursor = start;
    int spaces = 0;
    while (cursor < end && text.codeUnitAt(cursor) == _space && spaces < 3) {
      cursor++;
      spaces++;
    }
    if (cursor >= end) return null;
    final int unit = text.codeUnitAt(cursor);
    if (unit != _backtick && unit != _tilde) return null;
    int length = 0;
    while (cursor + length < end && text.codeUnitAt(cursor + length) == unit) {
      length++;
    }
    if (length < 3) return null;
    if (unit == _backtick) {
      // An info string cannot contain a backtick, or this is inline code.
      for (int index = cursor + length; index < end; index++) {
        if (text.codeUnitAt(index) == _backtick) return null;
      }
    }
    return _Fence(unit, length, quoted: (base & MdFlag.quote) != 0);
  }

  void _fenceLine(int lineStart, int end, _Fence fence) {
    int start = lineStart;
    if (fence.quoted) {
      // Lines of a fenced block inside a quote keep their `>` prefix.
      while (true) {
        int probe = start;
        int skipped = 0;
        while (probe < end && text.codeUnitAt(probe) == _space && skipped < 3) {
          probe++;
          skipped++;
        }
        if (probe < end && text.codeUnitAt(probe) == _gt) {
          probe++;
          if (probe < end && text.codeUnitAt(probe) == _space) probe++;
          start = probe;
        } else {
          break;
        }
      }
      _emit(lineStart, start, MdFlag.marker | MdFlag.quote);
    }
    int cursor = start;
    int spaces = 0;
    while (cursor < end && text.codeUnitAt(cursor) == _space && spaces < 3) {
      cursor++;
      spaces++;
    }
    int length = 0;
    while (cursor + length < end &&
        text.codeUnitAt(cursor + length) == fence.unit) {
      length++;
    }
    bool closing = length >= fence.length;
    if (closing) {
      for (int index = cursor + length; index < end; index++) {
        if (!_isSpace(text.codeUnitAt(index))) {
          closing = false;
          break;
        }
      }
    }
    if (closing) {
      _fence = null;
      _emit(start, end, MdFlag.codeBlock | MdFlag.marker);
    } else {
      _emit(start, end, MdFlag.codeBlock);
    }
  }

  bool _heading(int start, int end, int base) {
    int cursor = start;
    int spaces = 0;
    while (cursor < end && text.codeUnitAt(cursor) == _space && spaces < 3) {
      cursor++;
      spaces++;
    }
    int hashes = 0;
    while (cursor + hashes < end && text.codeUnitAt(cursor + hashes) == _hash) {
      hashes++;
    }
    if (hashes < 1 || hashes > 6) return false;
    final int after = cursor + hashes;
    if (after < end && !_isSpace(text.codeUnitAt(after))) return false;
    int contentStart = after;
    while (contentStart < end && _isSpace(text.codeUnitAt(contentStart))) {
      contentStart++;
    }
    int contentEnd = end;
    while (contentEnd > contentStart &&
        _isSpace(text.codeUnitAt(contentEnd - 1))) {
      contentEnd--;
    }
    // A closing run of hashes, as in `## Title ##`, is syntax rather than text.
    int closingStart = contentEnd;
    while (closingStart > contentStart &&
        text.codeUnitAt(closingStart - 1) == _hash) {
      closingStart--;
    }
    if (closingStart < contentEnd &&
        (closingStart == contentStart ||
            _isSpace(text.codeUnitAt(closingStart - 1)))) {
      int trimmed = closingStart;
      while (trimmed > contentStart &&
          _isSpace(text.codeUnitAt(trimmed - 1))) {
        trimmed--;
      }
      _emit(start, contentStart, base | MdFlag.marker | hashes);
      _inline(contentStart, trimmed, base | hashes);
      _emit(trimmed, end, base | MdFlag.marker | hashes);
      return true;
    }
    _emit(start, contentStart, base | MdFlag.marker | hashes);
    _inline(contentStart, contentEnd, base | hashes);
    _emit(contentEnd, end, base | hashes);
    return true;
  }

  bool _isRule(int start, int end) {
    int cursor = start;
    int spaces = 0;
    while (cursor < end && text.codeUnitAt(cursor) == _space && spaces < 3) {
      cursor++;
      spaces++;
    }
    if (cursor >= end) return false;
    final int unit = text.codeUnitAt(cursor);
    if (unit != _dash && unit != _star && unit != _underscore) return false;
    int count = 0;
    for (int index = cursor; index < end; index++) {
      final int current = text.codeUnitAt(index);
      if (current == unit) {
        count++;
      } else if (!_isSpace(current)) {
        return false;
      }
    }
    return count >= 3;
  }

  bool _listItem(int start, int end, int base) {
    int cursor = start;
    while (cursor < end && _isSpace(text.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor >= end) return false;
    final int unit = text.codeUnitAt(cursor);
    int markerEnd;
    if (unit == _dash || unit == _plus || unit == _star) {
      markerEnd = cursor + 1;
    } else if (_isDigit(unit)) {
      int digits = 0;
      while (cursor + digits < end && _isDigit(text.codeUnitAt(cursor + digits))) {
        digits++;
      }
      if (digits > 9 || cursor + digits >= end) return false;
      final int terminator = text.codeUnitAt(cursor + digits);
      if (terminator != 0x2E && terminator != _rparen) return false;
      markerEnd = cursor + digits + 1;
    } else {
      return false;
    }
    if (markerEnd < end && !_isSpace(text.codeUnitAt(markerEnd))) return false;
    int contentStart = markerEnd;
    while (contentStart < end && _isSpace(text.codeUnitAt(contentStart))) {
      contentStart++;
    }
    // A task list checkbox directly after the bullet.
    int taskEnd = contentStart;
    if (contentStart + 2 < end &&
        text.codeUnitAt(contentStart) == _lbracket &&
        text.codeUnitAt(contentStart + 2) == _rbracket) {
      final int state = text.codeUnitAt(contentStart + 1);
      final bool boxed = state == _space || state == 0x78 || state == 0x58;
      final int afterBox = contentStart + 3;
      if (boxed && (afterBox >= end || _isSpace(text.codeUnitAt(afterBox)))) {
        taskEnd = afterBox;
        while (taskEnd < end && _isSpace(text.codeUnitAt(taskEnd))) {
          taskEnd++;
        }
      }
    }
    _emit(cursor, taskEnd > contentStart ? taskEnd : contentStart,
        base | MdFlag.listMarker);
    _inline(taskEnd > contentStart ? taskEnd : contentStart, end, base);
    return true;
  }

  bool _isTableDelimiter(int start, int end) {
    bool sawDash = false;
    bool sawPipe = false;
    for (int index = start; index < end; index++) {
      final int unit = text.codeUnitAt(index);
      if (unit == _dash) {
        sawDash = true;
      } else if (unit == _pipe) {
        sawPipe = true;
      } else if (unit != _colon && !_isSpace(unit)) {
        return false;
      }
    }
    return sawDash && sawPipe;
  }

  bool _isTableRow(int start, int end) {
    int firstPipe = -1;
    for (int index = start; index < end; index++) {
      if (text.codeUnitAt(index) == _pipe) {
        firstPipe = index;
        break;
      }
    }
    if (firstPipe < 0) return false;
    int cursor = start;
    while (cursor < end && _isSpace(text.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor < end && text.codeUnitAt(cursor) == _pipe) return true;
    if (_inTable) return true;
    return _nextLineIsTableDelimiter(end);
  }

  bool _nextLineIsTableDelimiter(int end) {
    int lineStart = end;
    if (lineStart < text.length && text.codeUnitAt(lineStart) == 0x0D) {
      lineStart++;
    }
    if (lineStart >= text.length || text.codeUnitAt(lineStart) != 0x0A) {
      return false;
    }
    lineStart++;
    final int newline = text.indexOf('\n', lineStart);
    int lineEnd = newline < 0 ? text.length : newline;
    if (lineEnd > lineStart && text.codeUnitAt(lineEnd - 1) == 0x0D) lineEnd--;
    return lineEnd > lineStart && _isTableDelimiter(lineStart, lineEnd);
  }

  // ---------------------------------------------------------------------------
  // Inline structure
  // ---------------------------------------------------------------------------

  void _inline(int start, int end, int base, {bool tableRow = false}) {
    final int length = end - start;
    if (length <= 0) return;
    final Uint16List flags = Uint16List(length);
    // Characters that cannot take part in emphasis: code, destinations, raw
    // HTML and backslash-escaped punctuation.
    final Uint8List blocked = Uint8List(length);

    void paint(int from, int to, int flag) {
      for (int index = from; index < to; index++) {
        flags[index - start] |= flag;
      }
    }

    void block(int from, int to) {
      for (int index = from; index < to; index++) {
        blocked[index - start] = 1;
      }
    }

    int index = start;
    while (index < end) {
      final int unit = text.codeUnitAt(index);
      if (unit == _backslash &&
          index + 1 < end &&
          _isAsciiPunctuation(text.codeUnitAt(index + 1))) {
        block(index, index + 2);
        index += 2;
        continue;
      }
      if (unit == _backtick) {
        final int? close = _codeSpanEnd(index, end);
        if (close != null) {
          int ticks = 0;
          while (index + ticks < end && text.codeUnitAt(index + ticks) == _backtick) {
            ticks++;
          }
          paint(index, index + ticks, MdFlag.code | MdFlag.marker);
          paint(index + ticks, close - ticks, MdFlag.code);
          paint(close - ticks, close, MdFlag.code | MdFlag.marker);
          block(index, close);
          index = close;
          continue;
        }
        while (index < end && text.codeUnitAt(index) == _backtick) {
          blocked[index - start] = 1;
          index++;
        }
        continue;
      }
      if (unit == _lt) {
        final int? close = _angleEnd(index, end);
        if (close != null) {
          final bool autolink = _isAutolink(index + 1, close - 1);
          if (autolink) {
            paint(index, index + 1, MdFlag.marker);
            paint(index + 1, close - 1, MdFlag.link);
            paint(close - 1, close, MdFlag.marker);
          } else {
            paint(index, close, MdFlag.html);
          }
          block(index, close);
          index = close;
          continue;
        }
      }
      if (unit == _lbracket || (unit == _bang && index + 1 < end && text.codeUnitAt(index + 1) == _lbracket)) {
        final int? close = _link(index, end, paint, block);
        if (close != null) {
          index = close;
          continue;
        }
      }
      if ((unit == 0x68 || unit == 0x48) && _startsBareUrl(index, end)) {
        int urlEnd = index;
        while (urlEnd < end) {
          final int current = text.codeUnitAt(urlEnd);
          if (_isWhitespace(current) || current == _lt) break;
          urlEnd++;
        }
        while (urlEnd > index &&
            const <int>[0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x27, 0x22, _rparen, _rbracket]
                .contains(text.codeUnitAt(urlEnd - 1))) {
          urlEnd--;
        }
        paint(index, urlEnd, MdFlag.link);
        block(index, urlEnd);
        index = urlEnd;
        continue;
      }
      if (tableRow && unit == _pipe) {
        paint(index, index + 1, MdFlag.tablePipe);
      }
      index++;
    }

    _emphasis(start, end, flags, blocked, paint);

    int runStart = start;
    int runFlags = flags[0] | base;
    for (int cursor = start + 1; cursor < end; cursor++) {
      final int current = flags[cursor - start] | base;
      if (current != runFlags) {
        _emit(runStart, cursor, runFlags);
        runStart = cursor;
        runFlags = current;
      }
    }
    _emit(runStart, end, runFlags);
  }

  /// Returns the index just past the code span that opens at [start], or null.
  int? _codeSpanEnd(int start, int end) {
    int ticks = 0;
    while (start + ticks < end && text.codeUnitAt(start + ticks) == _backtick) {
      ticks++;
    }
    int index = start + ticks;
    while (index < end) {
      if (text.codeUnitAt(index) == _backtick) {
        int run = 0;
        while (index + run < end && text.codeUnitAt(index + run) == _backtick) {
          run++;
        }
        if (run == ticks) return index + run;
        index += run;
      } else {
        index++;
      }
    }
    return null;
  }

  /// Returns the index just past the `>` of a tag or autolink at [start].
  int? _angleEnd(int start, int end) {
    if (start + 1 >= end) return null;
    final int first = text.codeUnitAt(start + 1);
    final bool letter = (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A);
    if (!letter && first != 0x2F && first != _bang) return null;
    for (int index = start + 1; index < end; index++) {
      final int unit = text.codeUnitAt(index);
      if (unit == _gt) return index + 1;
      if (unit == _lt) return null;
    }
    return null;
  }

  bool _isAutolink(int start, int end) {
    if (end <= start) return false;
    int colon = -1;
    for (int index = start; index < end; index++) {
      final int unit = text.codeUnitAt(index);
      if (unit == _colon) {
        colon = index;
        break;
      }
      final bool schemeChar =
          (unit >= 0x41 && unit <= 0x5A) ||
          (unit >= 0x61 && unit <= 0x7A) ||
          _isDigit(unit) ||
          unit == _plus ||
          unit == 0x2E ||
          unit == _dash;
      if (!schemeChar) return false;
    }
    if (colon < start + 2) return false;
    for (int index = colon + 1; index < end; index++) {
      if (_isWhitespace(text.codeUnitAt(index))) return false;
    }
    return true;
  }

  bool _startsBareUrl(int index, int end) {
    if (index > 0) {
      final int before = text.codeUnitAt(index - 1);
      final bool boundary =
          _isWhitespace(before) || before == _lparen || before == _lt || before == _lbracket || before == 0x22;
      if (!boundary) return false;
    }
    const List<String> schemes = <String>['http://', 'https://'];
    for (final String scheme in schemes) {
      if (index + scheme.length < end &&
          text.substring(index, index + scheme.length).toLowerCase() == scheme) {
        return true;
      }
    }
    return false;
  }

  /// Marks a link or image that opens at [start] and returns the index past it.
  int? _link(
    int start,
    int end,
    void Function(int from, int to, int flag) paint,
    void Function(int from, int to) block,
  ) {
    final bool image = text.codeUnitAt(start) == _bang;
    final int open = image ? start + 1 : start;
    int depth = 0;
    int close = open;
    while (close < end) {
      final int unit = text.codeUnitAt(close);
      if (unit == _backslash) {
        close += 2;
        continue;
      }
      if (unit == _backtick) {
        final int? span = _codeSpanEnd(close, end);
        if (span != null) {
          close = span;
          continue;
        }
      }
      if (unit == _lbracket) {
        depth++;
      } else if (unit == _rbracket) {
        depth--;
        if (depth == 0) break;
      }
      close++;
    }
    if (close >= end || depth != 0) return null;
    if (close + 1 >= end || text.codeUnitAt(close + 1) != _lparen) return null;
    int parenDepth = 1;
    int destinationEnd = close + 2;
    while (destinationEnd < end) {
      final int unit = text.codeUnitAt(destinationEnd);
      if (unit == _backslash) {
        destinationEnd += 2;
        continue;
      }
      if (unit == _lparen) {
        parenDepth++;
      } else if (unit == _rparen) {
        parenDepth--;
        if (parenDepth == 0) break;
      }
      destinationEnd++;
    }
    if (destinationEnd >= end) return null;
    paint(start, open + 1, MdFlag.marker);
    paint(open + 1, close, MdFlag.link);
    paint(close, close + 2, MdFlag.marker);
    paint(close + 2, destinationEnd, MdFlag.url);
    block(close + 2, destinationEnd);
    paint(destinationEnd, destinationEnd + 1, MdFlag.marker);
    return destinationEnd + 1;
  }

  /// Marks `*`, `_` and `~~` emphasis in one line using the delimiter-run
  /// method from CommonMark, simplified to what styling needs.
  void _emphasis(
    int start,
    int end,
    Uint16List flags,
    Uint8List blocked,
    void Function(int from, int to, int flag) paint,
  ) {
    final List<_Delimiter> stack = <_Delimiter>[];
    int index = start;
    while (index < end) {
      final int unit = text.codeUnitAt(index);
      if ((unit != _star && unit != _underscore && unit != _tilde) ||
          blocked[index - start] == 1) {
        index++;
        continue;
      }
      int count = 0;
      while (index + count < end &&
          text.codeUnitAt(index + count) == unit &&
          blocked[index + count - start] == 0) {
        count++;
      }
      final int before = index == 0 ? 0x20 : text.codeUnitAt(index - 1);
      final int after = index + count >= text.length ? 0x20 : text.codeUnitAt(index + count);
      final bool beforeSpace = _isWhitespace(before);
      final bool afterSpace = _isWhitespace(after);
      final bool beforePunct = _isPunctuation(before);
      final bool afterPunct = _isPunctuation(after);
      final bool leftFlanking = !afterSpace && (!afterPunct || beforeSpace || beforePunct);
      final bool rightFlanking = !beforeSpace && (!beforePunct || afterSpace || afterPunct);
      bool canOpen;
      bool canClose;
      if (unit == _underscore) {
        canOpen = leftFlanking && (!rightFlanking || beforePunct);
        canClose = rightFlanking && (!leftFlanking || afterPunct);
      } else {
        canOpen = leftFlanking;
        canClose = rightFlanking;
      }
      if (unit == _tilde && count != 2) {
        index += count;
        continue;
      }
      _processCloser(
        stack,
        _Delimiter(
          position: index,
          unit: unit,
          count: count,
          canOpen: canOpen,
          canClose: canClose,
        ),
        paint,
      );
      index += count;
    }
  }

  void _processCloser(
    List<_Delimiter> stack,
    _Delimiter run,
    void Function(int from, int to, int flag) paint,
  ) {
    if (run.canClose) {
      while (run.count > 0) {
        int openerIndex = -1;
        for (int candidate = stack.length - 1; candidate >= 0; candidate--) {
          final _Delimiter opener = stack[candidate];
          if (opener.unit != run.unit || !opener.canOpen) continue;
          // CommonMark's "multiple of three" rule, for runs that can both
          // open and close.
          if ((opener.canClose || run.canOpen) &&
              (opener.count + run.count) % 3 == 0 &&
              (opener.count % 3 != 0 || run.count % 3 != 0) &&
              run.unit != _tilde) {
            continue;
          }
          openerIndex = candidate;
          break;
        }
        if (openerIndex < 0) break;
        final _Delimiter opener = stack[openerIndex];
        final int use = run.unit == _tilde
            ? 2
            : (run.count >= 2 && opener.count >= 2 ? 2 : 1);
        final int openerUsedStart = opener.position + opener.count - use;
        final int contentStart = opener.position + opener.count;
        final int contentEnd = run.position;
        final int flag = run.unit == _tilde
            ? MdFlag.strike
            : (use == 2 ? MdFlag.bold : MdFlag.italic);
        paint(openerUsedStart, openerUsedStart + use, MdFlag.marker | flag);
        paint(contentStart, contentEnd, flag);
        paint(run.position, run.position + use, MdFlag.marker | flag);
        opener.count -= use;
        run.position += use;
        run.count -= use;
        stack.removeRange(openerIndex + 1, stack.length);
        if (opener.count == 0) stack.removeAt(openerIndex);
      }
    }
    if (run.count > 0 && run.canOpen) stack.add(run);
  }
}
