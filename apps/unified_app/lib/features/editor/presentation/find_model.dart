import 'package:flutter/widgets.dart';

/// Search state for the find and replace bar of a text editor.
///
/// Matching is plain text unless [useRegex] is set. Case and whole-word
/// options apply to both. The model only describes matches; moving the
/// selection and editing the text is left to the editor that owns it.
final class FindModel extends ChangeNotifier {
  FindModel();

  /// Matches beyond this are counted as "more" rather than listed, so a search
  /// for a single letter in a large file stays cheap.
  static const int maxMatches = 20000;

  /// The most matches painted behind the text at once.
  static const int maxHighlights = 2000;

  String _query = '';
  String _replacement = '';
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _useRegex = false;
  bool _visible = false;
  bool _replaceVisible = false;
  List<TextRange> _matches = const <TextRange>[];
  int _current = -1;
  bool _capped = false;
  String? _error;
  String _lastText = '';

  String get query => _query;
  String get replacement => _replacement;
  bool get caseSensitive => _caseSensitive;
  bool get wholeWord => _wholeWord;
  bool get useRegex => _useRegex;
  bool get visible => _visible;
  bool get replaceVisible => _replaceVisible;

  /// Every match in the text, in order.
  List<TextRange> get matches => _matches;

  /// Index into [matches] of the current match, or -1.
  int get current => _current;

  /// True when the text holds more than [maxMatches] matches.
  bool get capped => _capped;

  /// A message when the regular expression is invalid.
  String? get error => _error;

  TextRange? get currentMatch =>
      _current >= 0 && _current < _matches.length ? _matches[_current] : null;

  /// The matches to paint, trimmed around the current one.
  List<TextRange> get highlights {
    if (_matches.length <= maxHighlights) return _matches;
    final int center = _current < 0 ? 0 : _current;
    final int from = (center - maxHighlights ~/ 2).clamp(
      0,
      _matches.length - maxHighlights,
    );
    return _matches.sublist(from, from + maxHighlights);
  }

  /// Index of [current] within [highlights].
  int get highlightedCurrent {
    if (_current < 0) return -1;
    if (_matches.length <= maxHighlights) return _current;
    final int from = (_current - maxHighlights ~/ 2).clamp(
      0,
      _matches.length - maxHighlights,
    );
    return _current - from;
  }

  void show({bool replace = false}) {
    final bool showReplace = replace || _replaceVisible;
    if (_visible && _replaceVisible == showReplace) return;
    _visible = true;
    _replaceVisible = showReplace;
    notifyListeners();
  }

  void hide() {
    if (!_visible) return;
    _visible = false;
    _matches = const <TextRange>[];
    _current = -1;
    notifyListeners();
  }

  void toggleReplace() {
    _replaceVisible = !_replaceVisible;
    notifyListeners();
  }

  /// Applies new options and recomputes the matches against [text].
  void configure({
    String? query,
    String? replacement,
    bool? caseSensitive,
    bool? wholeWord,
    bool? useRegex,
    required String text,
    int anchor = 0,
  }) {
    _query = query ?? _query;
    _replacement = replacement ?? _replacement;
    _caseSensitive = caseSensitive ?? _caseSensitive;
    _wholeWord = wholeWord ?? _wholeWord;
    _useRegex = useRegex ?? _useRegex;
    recompute(text, anchor: anchor);
  }

  /// Recomputes the matches after the text changed. The current match becomes
  /// the first one at or after [anchor], usually the caret.
  void recompute(String text, {int anchor = 0}) {
    _lastText = text;
    _error = null;
    final RegExp? pattern = _pattern();
    if (pattern == null) {
      _matches = const <TextRange>[];
      _current = -1;
      _capped = false;
      notifyListeners();
      return;
    }
    final List<TextRange> found = <TextRange>[];
    bool capped = false;
    for (final RegExpMatch match in pattern.allMatches(text)) {
      if (match.end == match.start) continue;
      if (_wholeWord && !_isWholeWord(text, match.start, match.end)) continue;
      if (found.length >= maxMatches) {
        capped = true;
        break;
      }
      found.add(TextRange(start: match.start, end: match.end));
    }
    _matches = found;
    _capped = capped;
    _current = -1;
    for (int index = 0; index < found.length; index++) {
      if (found[index].start >= anchor) {
        _current = index;
        break;
      }
    }
    if (_current < 0 && found.isNotEmpty) _current = 0;
    notifyListeners();
  }

  /// Moves to the next match, wrapping at the end.
  TextRange? next() {
    if (_matches.isEmpty) return null;
    _current = (_current + 1) % _matches.length;
    notifyListeners();
    return _matches[_current];
  }

  /// Moves to the previous match, wrapping at the start.
  TextRange? previous() {
    if (_matches.isEmpty) return null;
    _current = _current <= 0 ? _matches.length - 1 : _current - 1;
    notifyListeners();
    return _matches[_current];
  }

  /// Makes the match at or after [offset] the current one.
  TextRange? moveTo(int offset) {
    if (_matches.isEmpty) return null;
    for (int index = 0; index < _matches.length; index++) {
      if (_matches[index].start >= offset) {
        _current = index;
        notifyListeners();
        return _matches[index];
      }
    }
    _current = 0;
    notifyListeners();
    return _matches[0];
  }

  /// The text with the current match replaced, and the offset just after the
  /// replacement, or null when there is no current match.
  ({String text, int caret})? replaceCurrent(String text) {
    final TextRange? target = currentMatch;
    final RegExp? pattern = _pattern();
    if (target == null || pattern == null) return null;
    final Match? match = pattern.matchAsPrefix(text, target.start);
    final String replacement = match == null
        ? _replacement
        : _expand(match);
    return (
      text: text.replaceRange(target.start, target.end, replacement),
      caret: target.start + replacement.length,
    );
  }

  /// The text with every match replaced, or null when nothing matches.
  String? replaceAll(String text) {
    final RegExp? pattern = _pattern();
    if (pattern == null || _matches.isEmpty) return null;
    return text.replaceAllMapped(pattern, (Match match) {
      if (match.end == match.start) return match[0]!;
      if (_wholeWord && !_isWholeWord(text, match.start, match.end)) {
        return match[0]!;
      }
      return _expand(match);
    });
  }

  /// How many matches [replaceAll] would replace.
  int get replaceAllCount => _matches.length;

  String _expand(Match match) {
    if (!_useRegex) return _replacement;
    return _replacement.replaceAllMapped(RegExp(r'\$(\$|&|\d)'), (Match token) {
      final String code = token.group(1)!;
      if (code == r'$') return r'$';
      if (code == '&') return match[0]!;
      final int group = int.parse(code);
      return group <= match.groupCount ? (match[group] ?? '') : '';
    });
  }

  RegExp? _pattern() {
    if (_query.isEmpty) return null;
    try {
      return RegExp(
        _useRegex ? _query : RegExp.escape(_query),
        caseSensitive: _caseSensitive,
        multiLine: true,
      );
    } on FormatException catch (error) {
      _error = error.message;
      return null;
    }
  }

  static bool _isWordUnit(int unit) =>
      (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A) ||
      unit == 0x5F ||
      unit > 0x7F;

  static bool _isWholeWord(String text, int start, int end) {
    if (start > 0 && _isWordUnit(text.codeUnitAt(start - 1))) return false;
    if (end < text.length && _isWordUnit(text.codeUnitAt(end))) return false;
    return true;
  }

  /// The text the matches were last computed against.
  String get lastText => _lastText;

  /// Sets the replacement text. It changes no matches, so nothing is repainted.
  void setReplacement(String value) {
    _replacement = value;
  }
}
