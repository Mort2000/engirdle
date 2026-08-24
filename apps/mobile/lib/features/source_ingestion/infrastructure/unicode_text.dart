/// Python-parity text primitives shared by the markdown parser, the plain-text
/// structurer and the segmenter (contracts/source/v1).
///
/// The PC pipeline (markdown.py) defines the exact behavior: NFKC → smart
/// character mapping → Cc control filter for *visible* text; Unicode-aware
/// predicates for segmentation. Dart's `String.length` counts UTF-16 units, so
/// every length that PC computes in codepoints goes through [codePointLength].
library;

import 'package:unorm_dart/unorm_dart.dart' as unorm;

const _smartCharacters = <int, String>{
  0x2018: "'", // ‘
  0x2019: "'", // ’
  0x201C: '"', // “
  0x201D: '"', // ”
  0x2013: '-', // –
  0x2014: '--', // —
  0x00A0: ' ', // no-break space
};

/// Visible-prose projection: NFKC, smart quotes/dashes, control filter
/// (keeps \n and \t). Deliberately NOT applied to code bodies, inline code
/// literals or link URIs.
String normalizeVisibleText(String text) {
  final normalized = unorm.nfkc(text);
  final out = StringBuffer();
  for (final rune in normalized.runes) {
    final mapped = _smartCharacters[rune];
    if (mapped != null) {
      out.write(mapped);
    } else if (rune == 0x0A || rune == 0x09 || !isControl(rune)) {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// Unicode Cc (control) category: C0/C1 controls.
bool isControl(int rune) =>
    (rune >= 0x00 && rune <= 0x1F) || (rune >= 0x7F && rune <= 0x9F);

/// Python `str.isspace()`: Zs + [\t\n\v\f\r\x1c\x1d\x1e\x1f\x85].
bool isPythonSpace(int rune) {
  if (rune == 0x09 ||
      rune == 0x0A ||
      rune == 0x0B ||
      rune == 0x0C ||
      rune == 0x0D ||
      rune == 0x1C ||
      rune == 0x1D ||
      rune == 0x1E ||
      rune == 0x1F ||
      rune == 0x85) {
    return true;
  }
  return isUnicodeSpaceSeparator(rune);
}

/// Zs category.
bool isUnicodeSpaceSeparator(int rune) => switch (rune) {
  0x20 || 0xA0 || 0x1680 => true,
  >= 0x2000 && <= 0x200A => true,
  0x202F || 0x205F || 0x3000 => true,
  _ => false,
};

/// Python `str.islower()` for a single codepoint (cased and lowercase). ASCII
/// fast path; non-ASCII uses the platform case mapping and requires it to stay
/// single-codepoint (ß-style expansions don't count).
bool isPythonLower(int rune) {
  if (rune >= 0x61 && rune <= 0x7A) return true;
  if (rune < 0x80) return false;
  final s = String.fromCharCode(rune);
  final upper = s.toUpperCase();
  return upper != s && upper.length == 1 && s.toLowerCase() == s;
}

/// Python `str.isupper()` counterpart.
bool isPythonUpper(int rune) {
  if (rune >= 0x41 && rune <= 0x5A) return true;
  if (rune < 0x80) return false;
  final s = String.fromCharCode(rune);
  final lower = s.toLowerCase();
  return lower != s && lower.length == 1 && s.toUpperCase() == s;
}

/// Python `str.isalpha()` approximation: ASCII letters + the common Unicode
/// letter blocks (prose scripts). Exotic letters outside these ranges read as
/// non-letters; the shared fixtures pin the covered alphabet.
bool isPythonAlpha(int rune) {
  if (rune >= 0x41 && rune <= 0x5A) return true;
  if (rune >= 0x61 && rune <= 0x7A) return true;
  if (rune < 0x80) return false;
  return switch (rune) {
    >= 0x00C0 && <= 0x024F => true, // Latin-1 supplement + extended
    >= 0x0370 && <= 0x04FF => true, // Greek + Cyrillic
    >= 0x0590 && <= 0x05FF => true, // Hebrew
    >= 0x0600 && <= 0x06FF => true, // Arabic
    >= 0x0900 && <= 0x0DFF => true, // Indic
    >= 0x3040 && <= 0x30FF => true, // Hiragana/Katakana
    >= 0x3400 && <= 0x4DBF => true, // CJK ext A
    >= 0x4E00 && <= 0x9FFF => true, // CJK unified
    >= 0xAC00 && <= 0xD7AF => true, // Hangul
    >= 0xF900 && <= 0xFAFF => true, // CJK compat ideographs
    _ => false,
  };
}

/// Python `str.isdigit()` approximation: ASCII digits + common Nd blocks.
bool isPythonDigit(int rune) {
  if (rune >= 0x30 && rune <= 0x39) return true;
  if (rune < 0x80) return false;
  return switch (rune) {
    >= 0x0660 && <= 0x0669 => true, // Arabic-Indic
    >= 0x0966 && <= 0x096F => true, // Devanagari
    >= 0xFF10 && <= 0xFF19 => true, // fullwidth
    _ => false,
  };
}

/// markdown-it `isPunctChar`: Unicode P or S category. ASCII exact; non-ASCII
/// covers the punctuation/symbol blocks the fixtures exercise.
bool isPunctChar(int rune) {
  if (rune < 0x80) {
    return (rune >= 0x21 && rune <= 0x2F) ||
        (rune >= 0x3A && rune <= 0x40) ||
        (rune >= 0x5B && rune <= 0x60) ||
        (rune >= 0x7B && rune <= 0x7E);
  }
  return switch (rune) {
    >= 0x00A1 && <= 0x00A9 => true,
    >= 0x00AB && <= 0x00AC => true,
    >= 0x00AE && <= 0x00B1 => true,
    0x00B6 || 0x00B7 || 0x00BB || 0x00BF => true,
    >= 0x2010 && <= 0x2027 => true, // general punctuation
    >= 0x2030 && <= 0x205E => true,
    >= 0x20A0 && <= 0x20BF => true, // currency symbols (S)
    >= 0x2190 && <= 0x2BFF => true, // arrows, math, misc symbols
    >= 0x3001 && <= 0x3003 => true, // CJK punctuation
    >= 0x3008 && <= 0x3011 => true,
    >= 0xFF01 && <= 0xFF0F => true, // fullwidth punct
    >= 0xFF1A && <= 0xFF20 => true,
    >= 0xFF3B && <= 0xFF40 => true,
    >= 0xFF5B && <= 0xFF65 => true,
    _ => false,
  };
}

/// markdown-it `isWhiteSpace(code)`: Zs + [\t\f\v\r\n] (inline flanking rule).
bool isInlineWhiteSpace(int rune) {
  if (rune == 0x09 ||
      rune == 0x0A ||
      rune == 0x0B ||
      rune == 0x0C ||
      rune == 0x0D ||
      rune == 0x20) {
    return true;
  }
  return isUnicodeSpaceSeparator(rune);
}

/// PC counts strings in codepoints; Dart strings count UTF-16 units.
int codePointLength(String text) => text.runes.length;
