import 'package:flutter/widgets.dart';

/// Shows tab characters at a sensible width.
///
/// Flutter lays a tab out like a single space, so tab-indented code would look
/// almost flat. A tab is widened by giving only that character extra letter
/// spacing. The text itself is not touched, so offsets, selection and the saved
/// bytes stay exactly as they are.
///
/// Every tab is [columns] spaces wide. It is not a tab stop, so a tab in the
/// middle of a line moves the text after it by the same amount as one that
/// starts the line.
abstract final class TabDisplay {
  /// How many columns a tab character is drawn across.
  static const int columns = 4;

  static final Map<String, double> _spacing = <String, double>{};

  /// Whether [codeUnit] ends a line, so the character after it starts one.
  static bool endsLine(int codeUnit) =>
      codeUnit == 0x0A ||
      codeUnit == 0x0D ||
      codeUnit == 0x0B ||
      codeUnit == 0x0C ||
      codeUnit == 0x85 ||
      codeUnit == 0x2028 ||
      codeUnit == 0x2029;

  /// The letter spacing that makes a tab in the middle of a line as wide as
  /// [columns] spaces in [style].
  static double letterSpacing(TextStyle style) {
    final String key =
        '${style.fontFamily}|${style.fontSize}|${style.fontWeight}|'
        '${style.fontStyle}|${style.fontFamilyFallback?.join(',')}';
    return _spacing.putIfAbsent(key, () {
      double width(String value) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: value, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        final double result = painter.width;
        painter.dispose();
        return result;
      }

      // A tab on its own can lay out differently from one between two
      // letters, so its width is read from the gap it opens in a word.
      final double tab = width('a\tb') - width('ab');
      final double extra = columns * width(' ') - tab;
      return extra < 0 ? 0 : extra;
    });
  }

  /// The letter spacing for a tab that is the first character of a line.
  ///
  /// Flutter moves a whole line right by half the letter spacing of its first
  /// character. For a tab that starts a line the spacing it adds and the shift
  /// together add up to one and a half times the spacing, so two thirds of
  /// the middle-of-line value lands the text after it on the same column.
  static double leadingLetterSpacing(TextStyle style) =>
      letterSpacing(style) / 1.5;

  /// Appends [value] to [out], cutting each tab into its own widened span.
  ///
  /// [segment] is the style layered over [inherited], the style of the
  /// surrounding text, to give the style the characters are drawn in.
  /// [atLineStart] says whether the first character of [value] starts a line.
  static void addText(
    List<InlineSpan> out,
    String value,
    TextStyle? segment,
    TextStyle inherited, {
    required bool atLineStart,
  }) {
    if (!value.contains('\t')) {
      out.add(TextSpan(text: value, style: segment));
      return;
    }
    final TextStyle effective = segment == null
        ? inherited
        : inherited.merge(segment);
    final TextStyle ownStyle = segment ?? const TextStyle();
    final TextStyle middleTab = ownStyle.copyWith(
      letterSpacing: letterSpacing(effective),
    );
    final TextStyle leadingTab = ownStyle.copyWith(
      letterSpacing: leadingLetterSpacing(effective),
    );
    int start = 0;
    bool lineStart = atLineStart;
    for (int index = 0; index < value.length; index++) {
      final int unit = value.codeUnitAt(index);
      if (unit == 0x09) {
        if (index > start) {
          out.add(
            TextSpan(text: value.substring(start, index), style: segment),
          );
        }
        out.add(
          TextSpan(text: '\t', style: lineStart ? leadingTab : middleTab),
        );
        start = index + 1;
      }
      lineStart = endsLine(unit);
    }
    if (start < value.length) {
      out.add(TextSpan(text: value.substring(start), style: segment));
    }
  }

  /// A copy of [span] in which every tab is widened, for span trees built by
  /// someone else, such as a syntax highlighter.
  ///
  /// The tree must start at the beginning of the text.
  static TextSpan expand(TextSpan span, TextStyle inherited) =>
      _expand(span, inherited, _LineCursor());

  static TextSpan _expand(
    TextSpan span,
    TextStyle inherited,
    _LineCursor cursor,
  ) {
    final TextStyle effective = span.style == null
        ? inherited
        : inherited.merge(span.style);
    final String? text = span.text;
    final List<InlineSpan>? children = span.children;
    final bool ownTabs = text != null && text.contains('\t');
    final List<InlineSpan> expanded = <InlineSpan>[];
    if (ownTabs) {
      addText(expanded, text, null, effective, atLineStart: cursor.atLineStart);
    }
    if (text != null && text.isNotEmpty) {
      cursor.atLineStart = endsLine(text.codeUnitAt(text.length - 1));
    }
    bool changed = ownTabs;
    for (final InlineSpan child in children ?? const <InlineSpan>[]) {
      if (child is TextSpan) {
        final TextSpan next = _expand(child, effective, cursor);
        changed = changed || !identical(next, child);
        expanded.add(next);
      } else {
        // Anything that is not text stands in for one character.
        cursor.atLineStart = false;
        expanded.add(child);
      }
    }
    if (!changed) return span;
    return TextSpan(
      text: ownTabs ? null : text,
      children: expanded,
      style: span.style,
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      onEnter: span.onEnter,
      onExit: span.onExit,
      semanticsLabel: span.semanticsLabel,
      locale: span.locale,
      spellOut: span.spellOut,
    );
  }
}

/// Where the walk through a span tree has got to.
final class _LineCursor {
  bool atLineStart = true;
}
