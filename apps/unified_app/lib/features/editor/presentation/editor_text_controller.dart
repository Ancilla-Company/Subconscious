import 'package:flutter/material.dart';

import 'editor_fonts.dart';
import 'markdown/markdown_tokenizer.dart';
import 'tab_display.dart';

/// A text controller that paints find matches over the text it edits.
///
/// Subclasses can add styling by returning style runs. The spans built from
/// those runs, the find highlights and the input method's composing underline
/// are all cut from the same list, so the text shown always matches the text
/// edited. The result is cached, because a text field asks for it on every
/// caret move and rebuilding it for a large document is expensive.
class EditorTextController extends TextEditingController {
  EditorTextController({super.text});

  List<TextRange> _matches = const <TextRange>[];
  int _currentMatch = -1;
  int _epoch = 0;

  String? _runsText;
  List<MdRun> _runs = const <MdRun>[];
  _SpanCache? _spanCache;

  /// Paints [matches] behind the text, with the one at [current] stressed.
  void setMatches(List<TextRange> matches, int current) {
    _matches = matches;
    _currentMatch = current;
    _epoch++;
    notifyListeners();
  }

  /// Forgets the cached styling so the next build recomputes it.
  @protected
  void invalidateStyling() {
    _runsText = null;
    _spanCache = null;
  }

  /// Style runs that cover [text] completely, or none for unstyled text.
  @protected
  List<MdRun> computeRuns(String text) => const <MdRun>[];

  /// The style layered over the base style for a run with [flags].
  @protected
  TextStyle? styleForFlags(int flags, TextStyle base, ThemeData theme) => null;

  /// The part of [text] that is drawn in full for [selection], even where
  /// [hiddenStyle] would hide it. Empty when nothing needs revealing.
  @protected
  TextRange revealedRange(String text, TextSelection selection) =>
      TextRange.empty;

  /// A style that hides [run] while keeping its characters in the text, or
  /// null to draw it normally. A hidden run keeps its place in the text, so
  /// offsets, selection and the saved bytes are unaffected.
  @protected
  TextStyle? hiddenStyle(MdRun run, TextRange revealed) => null;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final String text = this.text;
    final TextStyle base = style ?? const TextStyle();
    final ThemeData theme = Theme.of(context);
    final TextRange composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;

    final TextRange revealed = revealedRange(text, value.selection);

    final String? runsText = _runsText;
    if (runsText == null || !(identical(runsText, text) || runsText == text)) {
      _runsText = text;
      _runs = computeRuns(text);
      _spanCache = null;
    }
    final _SpanCache? cache = _spanCache;
    if (cache != null &&
        cache.epoch == _epoch &&
        cache.composing == composing &&
        cache.revealed == revealed &&
        cache.base == base &&
        cache.scheme == theme.colorScheme) {
      return cache.span;
    }

    final List<MdRun> runs = _runs.isEmpty
        ? <MdRun>[MdRun(0, text.length, 0)]
        : _runs;
    final Map<int, TextStyle?> styles = <int, TextStyle?>{};
    final Color matchColor = Colors.amber.withValues(alpha: 0.35);
    final Color currentColor = Colors.orange.withValues(alpha: 0.6);
    final List<InlineSpan> children = <InlineSpan>[];
    int matchIndex = 0;
    for (final MdRun run in runs) {
      final TextStyle? runStyle = styles.putIfAbsent(
        run.flags,
        () => styleForFlags(run.flags, base, theme),
      );
      int from = run.start;
      while (from < run.end) {
        int to = run.end;
        while (matchIndex < _matches.length &&
            _matches[matchIndex].end <= from) {
          matchIndex++;
        }
        bool inMatch = false;
        bool inCurrent = false;
        if (matchIndex < _matches.length) {
          final TextRange match = _matches[matchIndex];
          if (match.start <= from) {
            inMatch = true;
            inCurrent = matchIndex == _currentMatch;
            if (match.end < to) to = match.end;
          } else if (match.start < to) {
            to = match.start;
          }
        }
        bool inComposing = false;
        if (composing.isValid && !composing.isCollapsed) {
          if (composing.start <= from && from < composing.end) {
            inComposing = true;
            if (composing.end < to) to = composing.end;
          } else if (from < composing.start && composing.start < to) {
            to = composing.start;
          }
        }
        TextStyle? segment = hiddenStyle(run, revealed) ?? runStyle;
        if (inMatch) {
          segment = (segment ?? const TextStyle()).copyWith(
            backgroundColor: inCurrent ? currentColor : matchColor,
          );
        }
        if (inComposing) {
          final TextDecoration? existing = segment?.decoration;
          segment = (segment ?? const TextStyle()).copyWith(
            decoration: existing == null
                ? TextDecoration.underline
                : TextDecoration.combine(<TextDecoration>[
                    existing,
                    TextDecoration.underline,
                  ]),
          );
        }
        TabDisplay.addText(
          children,
          text.substring(from, to),
          segment,
          base,
          atLineStart: from == 0 || TabDisplay.endsLine(text.codeUnitAt(from - 1)),
        );
        from = to;
      }
    }
    final TextSpan span = TextSpan(style: base, children: children);
    _spanCache = _SpanCache(
      span: span,
      epoch: _epoch,
      composing: composing,
      revealed: revealed,
      base: base,
      scheme: theme.colorScheme,
    );
    return span;
  }
}

final class _SpanCache {
  const _SpanCache({
    required this.span,
    required this.epoch,
    required this.composing,
    required this.revealed,
    required this.base,
    required this.scheme,
  });

  final TextSpan span;
  final int epoch;
  final TextRange composing;
  final TextRange revealed;
  final TextStyle base;
  final ColorScheme scheme;
}

/// Markdown source with live styling.
///
/// The text is never altered: headings are larger, emphasis is bold or italic,
/// and the syntax characters stay visible but dimmed, so what is on screen is
/// exactly what is in the file.
final class MarkdownTextController extends EditorTextController {
  MarkdownTextController({super.text, bool styled = true}) {
    _styled = styled;
  }

  bool _styled = true;

  /// Whether the text is styled. Very large files turn this off, because
  /// restyling them on every keystroke would make typing lag.
  bool get styled => _styled;

  set styled(bool value) {
    if (_styled == value) return;
    _styled = value;
    invalidateStyling();
    notifyListeners();
  }

  static const List<double> _headingScale = <double>[
    1,
    1.7,
    1.45,
    1.25,
    1.1,
    1,
    0.95,
  ];

  @override
  List<MdRun> computeRuns(String text) =>
      _styled ? tokenizeMarkdown(text) : const <MdRun>[];

  /// Formatting symbols that can be hidden: the markers of emphasis, inline
  /// code, links, headings and quotes, and link destinations. Code fences,
  /// rules, tables and HTML stay visible.
  static const int _keepVisible =
      MdFlag.rule | MdFlag.codeBlock | MdFlag.tablePipe | MdFlag.html;

  /// The lines the selection touches. Their symbols are shown so the text can
  /// be edited, and every other line shows only the formatted result.
  @override
  TextRange revealedRange(String text, TextSelection selection) {
    if (!_styled || !selection.isValid) return TextRange.empty;
    final int start = selection.start.clamp(0, text.length);
    final int end = selection.end.clamp(0, text.length);
    final int lineStart = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    final int newline = text.indexOf('\n', end);
    return TextRange(start: lineStart, end: newline < 0 ? text.length : newline);
  }

  @override
  TextStyle? hiddenStyle(MdRun run, TextRange revealed) {
    final int flags = run.flags;
    final bool symbol = flags & (MdFlag.marker | MdFlag.url) != 0;
    if (!symbol || flags & _keepVisible != 0) return null;
    // A run on a revealed line is drawn in full. A caret at the very end of
    // the line still counts as on it.
    if (revealed.isValid && run.start <= revealed.end && run.end > revealed.start) {
      return null;
    }
    return const TextStyle(
      fontSize: 0.01,
      color: Colors.transparent,
      fontWeight: FontWeight.normal,
      fontStyle: FontStyle.normal,
      decoration: TextDecoration.none,
      letterSpacing: 0,
    );
  }

  @override
  TextStyle? styleForFlags(int flags, TextStyle base, ThemeData theme) {
    if (flags == 0) return null;
    final ColorScheme colors = theme.colorScheme;
    final Color text = base.color ?? colors.onSurface;
    final double size = base.fontSize ?? 14;
    final Color dim = text.withValues(alpha: 0.42);

    final int heading = flags & MdFlag.headingMask;
    double? fontSize;
    FontWeight? weight;
    FontStyle? fontStyle;
    TextDecoration? decoration;
    Color? color;
    Color? background;
    String? family;
    List<String>? fallback;

    if (heading > 0) {
      fontSize = size * _headingScale[heading];
      weight = FontWeight.w700;
    }
    if (flags & MdFlag.bold != 0) weight = FontWeight.w700;
    if (flags & MdFlag.italic != 0) fontStyle = FontStyle.italic;
    if (flags & MdFlag.strike != 0) decoration = TextDecoration.lineThrough;
    if (flags & MdFlag.quote != 0) color = colors.onSurfaceVariant;
    if (flags & MdFlag.code != 0) {
      family = editorMonospaceFamily;
      fallback = editorMonospaceFallback;
      if (heading == 0) fontSize = size * 0.93;
      background = colors.surfaceContainerHighest.withValues(alpha: 0.7);
    }
    if (flags & MdFlag.codeBlock != 0) {
      family = editorMonospaceFamily;
      fallback = editorMonospaceFallback;
      fontSize = size * 0.93;
      background = colors.surfaceContainerLow;
    }
    if (flags & MdFlag.link != 0) {
      color = colors.primary;
      decoration = decoration == null
          ? TextDecoration.underline
          : TextDecoration.combine(<TextDecoration>[
              decoration,
              TextDecoration.underline,
            ]);
    }
    if (flags & MdFlag.listMarker != 0) {
      color = colors.primary;
      weight = FontWeight.w700;
    }
    if (flags &
            (MdFlag.marker |
                MdFlag.url |
                MdFlag.rule |
                MdFlag.tablePipe |
                MdFlag.html) !=
        0) {
      color = dim;
    }
    return TextStyle(
      fontSize: fontSize,
      fontWeight: weight,
      fontStyle: fontStyle,
      decoration: decoration,
      color: color,
      backgroundColor: background,
      fontFamily: family,
      fontFamilyFallback: fallback,
    );
  }
}
