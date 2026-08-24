import 'unicode_text.dart';

/// Character spans of sentences in visible plain text — a verbatim port of
/// PC `_sentence_spans` / `period_is_nonterminal` (markdown.py), so the same
/// text segments identically on both platforms (contracts/source/v1 §对齐规则).
List<(int, int)> sentenceSpans(String text) {
  final spans = <(int, int)>[];
  var start = 0;
  var index = 0;
  final length = text.length;
  while (index < length) {
    final character = text.codeUnitAt(index);
    if (character != 0x2E && character != 0x21 && character != 0x3F) {
      index += 1;
      continue;
    }
    if (character == 0x2E && _periodIsNonterminal(text, index)) {
      index += 1;
      continue;
    }
    var end = index + 1;
    while (end < length && _isTerminator(text.codeUnitAt(end))) {
      end += 1;
    }
    while (end < length && _isClosingPunctuation(text.codeUnitAt(end))) {
      end += 1;
    }
    var nextStart = end;
    while (nextStart < length && isPythonSpace(text.codeUnitAt(nextStart))) {
      nextStart += 1;
    }
    if (nextStart < length && isPythonLower(_runeStartingAt(text, nextStart))) {
      index = end;
      continue;
    }
    if (_hasVisible(text, start, end)) {
      spans.add(_strippedSpan(text, start, end));
    }
    start = nextStart;
    index = nextStart;
  }
  if (_hasVisible(text, start, length)) {
    spans.add(_strippedSpan(text, start, length));
  }
  return spans;
}

bool _isTerminator(int codeUnit) =>
    codeUnit == 0x2E || codeUnit == 0x21 || codeUnit == 0x3F;

const _closingPunctuation = {
  0x22, // "
  0x27, // '
  0x2019, // ’
  0x201D, // ”
  0x29, // )
  0x5D, // ]
};

bool _isClosingPunctuation(int codeUnit) =>
    _closingPunctuation.contains(codeUnit);

bool _hasVisible(String text, int start, int end) {
  for (var i = start; i < end; i++) {
    if (!isPythonSpace(text.codeUnitAt(i))) return true;
  }
  return false;
}

(int, int) _strippedSpan(String text, int start, int end) {
  while (start < end && isPythonSpace(text.codeUnitAt(start))) {
    start += 1;
  }
  while (end > start && isPythonSpace(text.codeUnitAt(end - 1))) {
    end -= 1;
  }
  return (start, end);
}

/// UTF-16 index → the codepoint starting there (combines surrogate pairs).
/// Python indexes by codepoint; ASCII/BMP text is already aligned, and astral
/// characters only reach here through the lowercase-continuation check.
int _runeStartingAt(String text, int index) {
  final unit = text.codeUnitAt(index);
  if (unit >= 0xD800 && unit < 0xDC00 && index + 1 < text.length) {
    final low = text.codeUnitAt(index + 1);
    if (low >= 0xDC00 && low < 0xE000) {
      return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
    }
  }
  return unit;
}

const _nonterminalAbbreviations = {
  'dr',
  'e.g',
  'fig',
  'i.e',
  'jr',
  'mr',
  'mrs',
  'ms',
  'no',
  'prof',
  'sr',
  'st',
  'vs',
};

/// Whether the '.' at [index] continues the current sentence.
bool _periodIsNonterminal(String text, int index) {
  if (index > 0 &&
      index + 1 < text.length &&
      isPythonDigit(text.codeUnitAt(index - 1)) &&
      isPythonDigit(text.codeUnitAt(index + 1))) {
    return true;
  }
  var tokenStart = index;
  while (tokenStart > 0) {
    final rune = _runeAt(text, tokenStart - 1);
    if (!isPythonAlpha(rune) && rune != 0x2E) break;
    tokenStart -= 1;
  }
  final rawToken = text.substring(tokenStart, index);
  final token = rawToken.toLowerCase();
  if (_nonterminalAbbreviations.contains(token)) {
    return true;
  }
  if (codePointLength(rawToken) == 1 && _isUpperToken(rawToken)) {
    return true;
  }
  final dotted = '$token.';
  // (?:[a-z]\.){2,} — must cover the whole "token." string.
  final match = RegExp(r'^(?:[a-z]\.){2,}$').firstMatch(dotted);
  return match != null;
}

bool _isUpperToken(String token) {
  if (token.length != 1) return false;
  final rune = token.codeUnitAt(0);
  return isPythonUpper(rune);
}

int _runeAt(String text, int codeUnitIndex) {
  if (codeUnitIndex < 0 || codeUnitIndex >= text.length) return -1;
  return text.codeUnitAt(codeUnitIndex);
}
