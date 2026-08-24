/// Inline (span-level) parser producing a flat markdown-it token stream.
///
/// Implements the CommonMark inline algorithm (delimiter runs with flanking
/// rules, rule-of-three emphasis matching, bracket links) plus GFM
/// strikethrough pairs, mirroring what markdown-it feeds the PC walk. The
/// frozen mobile subset rejects autolinks, HTML entities and inline HTML
/// instead of parsing them (contracts/source/v1 README); link reference
/// resolution does not exist because reference definitions are rejected at
/// block level, so `[text][ref]` stays literal — matching a reference-free
/// document on PC.
library;

import '../../domain/source_parse_error.dart';
import '../unicode_text.dart';
import 'md_state.dart' show InlineToken;

final RegExp _uriAutolink = RegExp(
  r'^<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\x00-\x20]*>',
);
final RegExp _emailAutolink = RegExp(
  r"^<[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9]"
  r"(?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"
  r"(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*>",
);
final RegExp _entity = RegExp(
  r'^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});',
);
final RegExp _htmlOpenTag = RegExp(
  r'''^<[a-zA-Z][a-zA-Z0-9-]*(?:\s+[a-zA-Z_:][a-zA-Z0-9:._-]*(?:\s*=\s*(?:[^"'=<>`\x00-\x20]+|'[^']*'|"[^"]*"))?)*\s*/?>''',
);
final RegExp _htmlCloseTag = RegExp(r'^</[a-zA-Z][a-zA-Z0-9-]*\s*>');
final RegExp _htmlComment = RegExp(
  r'^<!--(?:-?[^>-](?:-?[^-])*)?-->',
  dotAll: true,
);
final RegExp _htmlProcessingInstruction = RegExp(r'^<\?[\s\S]*?\?>');
final RegExp _htmlDeclaration = RegExp(r'^<![A-Za-z][^>]*>');
final RegExp _htmlCdata = RegExp(r'^<!\[CDATA\[[\s\S]*?\]\]>');

const _asciiPunctuation = {
  0x21,
  0x22,
  0x23,
  0x24,
  0x25,
  0x26,
  0x27,
  0x28,
  0x29,
  0x2A,
  0x2B,
  0x2C,
  0x2D,
  0x2E,
  0x2F,
  0x3A,
  0x3B,
  0x3C,
  0x3D,
  0x3E,
  0x3F,
  0x40,
  0x5B,
  0x5C,
  0x5D,
  0x5E,
  0x5F,
  0x60,
  0x7B,
  0x7C,
  0x7D,
  0x7E,
};

class _Delim {
  _Delim({
    required this.marker,
    required this.count,
    required this.canOpen,
    required this.canClose,
    required this.token,
    this.isBracket = false,
    this.isImage = false,
    this.contentStart = 0,
  }) : origRunLength = count;

  final int marker;
  int count;

  /// The run length when created — the rule-of-three uses original lengths.
  final int origRunLength;
  final bool canOpen;
  final bool canClose;
  final bool isBracket;
  final bool isImage;

  /// Raw source offset just after the bracket opener (image alt extraction).
  final int contentStart;

  InlineToken token;
  bool active = true;
}

/// Parses inline [content] (raw, un-normalized) into a flat token stream.
List<InlineToken> parseInlineTokens(String content) =>
    _InlineParser(content).parse();

class _InlineParser {
  _InlineParser(this.src);

  final String src;
  final List<InlineToken> tokens = [];
  final List<_Delim> delims = [];

  List<InlineToken> parse() {
    var pos = 0;
    final max = src.length;
    while (pos < max) {
      final ch = src.codeUnitAt(pos);
      switch (ch) {
        case 0x0A:
          pos = _breakAt(pos);
        case 0x5C:
          pos = _escapeAt(pos);
        case 0x60:
          pos = _codeSpanAt(pos);
        case 0x2A || 0x5F:
          pos = _delimiterAt(pos);
        case 0x7E:
          pos = _tildeAt(pos);
        case 0x5B:
          pos = _bracketAt(pos, image: false);
        case 0x21:
          if (pos + 1 < max && src.codeUnitAt(pos + 1) == 0x5B) {
            pos = _bracketAt(pos, image: true);
          } else {
            pos = _textRun(pos);
          }
        case 0x5D:
          pos = _closeBracketAt(pos);
        case 0x3C:
          pos = _angleAt(pos);
        case 0x26:
          pos = _ampersandAt(pos);
        default:
          pos = _textRun(pos);
      }
    }
    _processEmphasis(-1);
    return tokens;
  }

  // ---- text and breaks -----------------------------------------------------

  bool _isSpecial(int codeUnit) => switch (codeUnit) {
    0x0A ||
    0x5C ||
    0x60 ||
    0x2A ||
    0x5F ||
    0x7E ||
    0x5B ||
    0x5D ||
    0x3C ||
    0x26 => true,
    _ => false,
  };

  int _textRun(int pos) {
    final max = src.length;
    var end = pos;
    while (end < max) {
      final ch = src.codeUnitAt(end);
      if (_isSpecial(ch) ||
          (ch == 0x21 && end + 1 < max && src.codeUnitAt(end + 1) == 0x5B)) {
        break;
      }
      end += 1;
    }
    if (end == pos) end = pos + 1; // any unhandled special char is literal
    _pushText(src.substring(pos, end));
    return end;
  }

  int _breakAt(int pos) {
    // ≥2 trailing spaces (or backslash, handled separately) → hardbreak.
    final pending = tokens.isNotEmpty ? tokens.last : null;
    if (pending != null && pending.type == 'text') {
      var content = pending.content;
      var end = content.length;
      while (end > 0 &&
          (content.codeUnitAt(end - 1) == 0x20 ||
              content.codeUnitAt(end - 1) == 0x09)) {
        end -= 1;
      }
      final stripped = content.length - end;
      content = content.substring(0, end);
      if (content.isEmpty) {
        tokens.removeLast();
      } else {
        pending.content = content;
      }
      tokens.add(InlineToken(stripped >= 2 ? 'hardbreak' : 'softbreak'));
    } else {
      tokens.add(InlineToken('softbreak'));
    }
    var next = pos + 1;
    while (next < src.length &&
        (src.codeUnitAt(next) == 0x20 || src.codeUnitAt(next) == 0x09)) {
      next += 1;
    }
    return next;
  }

  int _escapeAt(int pos) {
    final max = src.length;
    if (pos + 1 >= max) {
      _pushText(r'\');
      return pos + 1;
    }
    final next = src.codeUnitAt(pos + 1);
    if (next == 0x0A) {
      tokens.add(InlineToken('hardbreak'));
      var after = pos + 2;
      while (after < max &&
          (src.codeUnitAt(after) == 0x20 || src.codeUnitAt(after) == 0x09)) {
        after += 1;
      }
      return after;
    }
    if (_asciiPunctuation.contains(next)) {
      _pushText(String.fromCharCode(next));
      return pos + 2;
    }
    _pushText(r'\');
    return pos + 1;
  }

  void _pushText(String text) {
    // No adjacent merging: delimiter runs live in their own text tokens and
    // the walk merges adjacent same-style runs anyway (PC `_inline`).
    if (text.isEmpty) return;
    tokens.add(InlineToken('text', content: text));
  }

  // ---- code spans ------------------------------------------------------------

  int _codeSpanAt(int pos) {
    final max = src.length;
    final start = pos;
    while (pos < max && src.codeUnitAt(pos) == 0x60) {
      pos += 1;
    }
    final length = pos - start;
    var search = pos;
    int? closeStart;
    while (search < max) {
      if (src.codeUnitAt(search) != 0x60) {
        search += 1;
        continue;
      }
      var runEnd = search;
      while (runEnd < max && src.codeUnitAt(runEnd) == 0x60) {
        runEnd += 1;
      }
      if (runEnd - search == length) {
        closeStart = search;
        break;
      }
      search = runEnd;
    }
    if (closeStart == null) {
      _pushText(src.substring(start, pos));
      return pos;
    }
    var content = src.substring(pos, closeStart).replaceAll('\n', ' ');
    if (content.length >= 2 &&
        content.startsWith(' ') &&
        content.endsWith(' ') &&
        content.trim().isNotEmpty) {
      content = content.substring(1, content.length - 1);
    }
    tokens.add(InlineToken('code_inline', content: content));
    return closeStart + length;
  }

  // ---- emphasis delimiters ---------------------------------------------------

  int _delimiterAt(int pos) {
    final max = src.length;
    final marker = src.codeUnitAt(pos);
    final start = pos;
    while (pos < max && src.codeUnitAt(pos) == marker) {
      pos += 1;
    }
    final count = pos - start;
    final (leftFlanking, rightFlanking, beforePunct, afterPunct) = _flanking(
      start,
      pos,
    );
    final canOpen = marker == 0x2A
        ? leftFlanking
        : leftFlanking && (!rightFlanking || beforePunct);
    final canClose = marker == 0x5F
        ? rightFlanking && (!leftFlanking || afterPunct)
        : rightFlanking;
    final token = InlineToken('text', content: src.substring(start, pos));
    tokens.add(token);
    delims.add(
      _Delim(
        marker: marker,
        count: count,
        canOpen: canOpen,
        canClose: canClose,
        token: token,
      ),
    );
    return pos;
  }

  /// (leftFlanking, rightFlanking, precededByPunct, followedByPunct)
  (bool, bool, bool, bool) _flanking(int start, int end) {
    final before = _runeBefore(start);
    final after = end < src.length ? _runeAt(end) : 0x0A;
    final beforeSpace = isInlineWhiteSpace(before);
    final afterSpace = isInlineWhiteSpace(after);
    final beforePunct = isPunctChar(before);
    final afterPunct = isPunctChar(after);
    final leftFlanking =
        !afterSpace && (!afterPunct || beforeSpace || beforePunct);
    final rightFlanking =
        !beforeSpace && (!beforePunct || afterSpace || afterPunct);
    return (leftFlanking, rightFlanking, beforePunct, afterPunct);
  }

  int _runeBefore(int index) {
    final i = index - 1;
    if (i < 0) return 0x0A;
    final unit = src.codeUnitAt(i);
    if (unit >= 0xDC00 && unit < 0xE000 && i > 0) {
      final high = src.codeUnitAt(i - 1);
      if (high >= 0xD800 && high < 0xDC00) {
        return 0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00);
      }
    }
    return unit;
  }

  int _runeAt(int index) {
    final unit = src.codeUnitAt(index);
    if (unit >= 0xD800 && unit < 0xDC00 && index + 1 < src.length) {
      final low = src.codeUnitAt(index + 1);
      if (low >= 0xDC00 && low < 0xE000) {
        return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
      }
    }
    return unit;
  }

  int _tildeAt(int pos) {
    final max = src.length;
    final start = pos;
    while (pos < max && src.codeUnitAt(pos) == 0x7E) {
      pos += 1;
    }
    final count = pos - start;
    if (count < 2) {
      _pushText(src.substring(start, pos));
      return pos;
    }
    // Odd runs split: a literal '~' plus ~~ pairs (markdown-it default).
    var consumed = 0;
    if (count.isOdd) {
      _pushText('~');
      consumed = 1;
    }
    final (leftFlanking, rightFlanking, _, _) = _flanking(
      start + consumed,
      pos,
    );
    while (consumed + 2 <= count) {
      final token = InlineToken('text', content: '~~');
      tokens.add(token);
      delims.add(
        _Delim(
          marker: 0x7E,
          count: 2,
          canOpen: leftFlanking,
          canClose: rightFlanking,
          token: token,
        ),
      );
      consumed += 2;
    }
    return pos;
  }

  // ---- brackets and links ------------------------------------------------------

  int _bracketAt(int pos, {required bool image}) {
    final token = InlineToken('text', content: image ? '![' : '[');
    tokens.add(token);
    delims.add(
      _Delim(
        marker: 0x5B,
        count: 1,
        canOpen: true,
        canClose: false,
        token: token,
        isBracket: true,
        isImage: image,
        contentStart: pos + (image ? 2 : 1),
      ),
    );
    return pos + (image ? 2 : 1);
  }

  int _closeBracketAt(int pos) {
    int? openerIndex;
    for (var i = delims.length - 1; i >= 0; i--) {
      if (delims[i].isBracket && delims[i].active) {
        openerIndex = i;
        break;
      }
    }
    if (openerIndex == null) {
      _pushText(']');
      return pos + 1;
    }
    final opener = delims[openerIndex];
    final tail = _parseLinkTail(pos + 1);
    if (tail == null) {
      _pushText(']');
      return pos + 1;
    }
    _processEmphasis(openerIndex);
    final openerTokenIndex = tokens.indexOf(opener.token);
    if (opener.isImage) {
      final children = tokens.sublist(openerTokenIndex + 1);
      tokens.removeRange(openerTokenIndex + 1, tokens.length);
      tokens.removeAt(openerTokenIndex);
      final image = InlineToken(
        'image',
        content: src.substring(opener.contentStart, pos),
        attrs: {'src': tail.$1},
      );
      image.children = children;
      tokens.add(image);
    } else {
      tokens[openerTokenIndex] = InlineToken(
        'link_open',
        attrs: {'href': tail.$1},
      );
      tokens.add(InlineToken('link_close'));
    }
    delims.removeRange(openerIndex, delims.length);
    return tail.$2;
  }

  (String, int)? _parseLinkTail(int pos) {
    final max = src.length;
    if (pos >= max || src.codeUnitAt(pos) != 0x28) return null;
    var p = pos + 1;
    while (p < max &&
        (src.codeUnitAt(p) == 0x20 || src.codeUnitAt(p) == 0x09)) {
      p += 1;
    }
    String dest;
    if (p < max && src.codeUnitAt(p) == 0x3C) {
      final close = src.indexOf('>', p + 1);
      if (close < 0 || close > _endOfLine(p)) return null;
      final raw = src.substring(p + 1, close);
      if (raw.contains('\n') || _hasUnescaped(raw, 0x3C)) return null;
      dest = _unescape(raw);
      p = close + 1;
    } else {
      final bare = _parseBareDestination(p);
      if (bare == null) return null;
      dest = bare.$1;
      p = bare.$2;
    }
    var q = p;
    while (q < max &&
        (src.codeUnitAt(q) == 0x20 ||
            src.codeUnitAt(q) == 0x09 ||
            src.codeUnitAt(q) == 0x0A)) {
      q += 1;
    }
    if (q < max &&
        (src.codeUnitAt(q) == 0x22 ||
            src.codeUnitAt(q) == 0x27 ||
            src.codeUnitAt(q) == 0x28)) {
      final titleEnd = _parseTitle(q);
      if (titleEnd == null) return null;
      q = titleEnd;
      while (q < max &&
          (src.codeUnitAt(q) == 0x20 ||
              src.codeUnitAt(q) == 0x09 ||
              src.codeUnitAt(q) == 0x0A)) {
        q += 1;
      }
      if (q >= max || src.codeUnitAt(q) != 0x29) return null;
      final href = _normalizeHref(dest);
      if (href == null) return null;
      return (href, q + 1);
    }
    if (p < max && src.codeUnitAt(p) == 0x29) {
      final href = _normalizeHref(dest);
      if (href == null) return null;
      return (href, p + 1);
    }
    return null;
  }

  int _endOfLine(int pos) {
    final nl = src.indexOf('\n', pos);
    return nl < 0 ? src.length : nl;
  }

  (String, int)? _parseBareDestination(int pos) {
    final max = src.length;
    var p = pos;
    var depth = 0;
    final out = StringBuffer();
    while (p < max) {
      final ch = src.codeUnitAt(p);
      if (ch == 0x5C &&
          p + 1 < max &&
          _asciiPunctuation.contains(src.codeUnitAt(p + 1))) {
        out.write(String.fromCharCode(src.codeUnitAt(p + 1)));
        p += 2;
        continue;
      }
      if (ch == 0x28) {
        depth += 1;
        if (depth > 32) return null;
        out.writeCharCode(ch);
        p += 1;
        continue;
      }
      if (ch == 0x29) {
        if (depth == 0) break;
        depth -= 1;
        out.writeCharCode(ch);
        p += 1;
        continue;
      }
      if (ch == 0x20 || ch == 0x09 || ch == 0x0A) break;
      if (ch < 0x20 || ch == 0x7F) return null;
      out.writeCharCode(ch);
      p += 1;
    }
    if (depth != 0) return null;
    return (out.toString(), p);
  }

  int? _parseTitle(int pos) {
    final max = src.length;
    final open = src.codeUnitAt(pos);
    final close = open == 0x28 ? 0x29 : open;
    var p = pos + 1;
    while (p < max) {
      final ch = src.codeUnitAt(p);
      if (ch == 0x5C &&
          p + 1 < max &&
          _asciiPunctuation.contains(src.codeUnitAt(p + 1))) {
        p += 2;
        continue;
      }
      if (ch == close) return p + 1;
      p += 1;
    }
    return null;
  }

  bool _hasUnescaped(String raw, int codeUnit) {
    for (var i = 0; i < raw.length; i++) {
      if (raw.codeUnitAt(i) != codeUnit) continue;
      var escaped = false;
      var j = i - 1;
      while (j >= 0 && raw.codeUnitAt(j) == 0x5C) {
        escaped = !escaped;
        j -= 1;
      }
      if (!escaped) return true;
    }
    return false;
  }

  String _unescape(String raw) {
    final out = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final ch = raw.codeUnitAt(i);
      if (ch == 0x5C &&
          i + 1 < raw.length &&
          _asciiPunctuation.contains(raw.codeUnitAt(i + 1))) {
        out.writeCharCode(raw.codeUnitAt(i + 1));
        i += 1;
        continue;
      }
      out.writeCharCode(ch);
    }
    return out.toString();
  }

  static final RegExp _badScheme = RegExp(
    r'^(?:javascript|vbscript|file|data):',
    caseSensitive: false,
  );
  static final RegExp _goodData = RegExp(
    r'^data:image/(?:gif|png|jpeg|webp);',
    caseSensitive: false,
  );

  /// mdurl/encodeURI-style normalization; rejected schemes yield null and the
  /// bracket stays literal (markdown-it validateLink).
  String? _normalizeHref(String dest) {
    final scheme = dest.trim().toLowerCase().replaceAll('\x00', '');
    if (_badScheme.hasMatch(scheme) && !_goodData.hasMatch(scheme)) {
      return null;
    }
    final out = StringBuffer();
    for (final rune in dest.runes) {
      if (_isUriSafe(rune)) {
        out.writeCharCode(rune);
      } else {
        out.write(_percentEncode(rune));
      }
    }
    return out.toString();
  }

  static bool _isUriSafe(int rune) {
    if (rune == 0x25) return false; // % re-encoded unless a valid escape
    if (rune < 0x80) {
      return (rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A) ||
          (rune >= 0x30 && rune <= 0x39) ||
          switch (rune) {
            0x21 ||
            0x23 ||
            0x24 ||
            0x26 ||
            0x27 ||
            0x28 ||
            0x29 ||
            0x2A ||
            0x2B ||
            0x2C ||
            0x2D ||
            0x2E ||
            0x2F ||
            0x3A ||
            0x3B ||
            0x3D ||
            0x3F ||
            0x40 ||
            0x5F ||
            0x7E => true,
            _ => false,
          };
    }
    return false;
  }

  static String _percentEncode(int rune) {
    final out = StringBuffer();
    for (final byte in utf8EncodeRune(rune)) {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
    return out.toString();
  }

  static List<int> utf8EncodeRune(int rune) {
    if (rune < 0x80) return [rune];
    if (rune < 0x800) return [0xC0 | (rune >> 6), 0x80 | (rune & 0x3F)];
    if (rune < 0x10000) {
      return [
        0xE0 | (rune >> 12),
        0x80 | ((rune >> 6) & 0x3F),
        0x80 | (rune & 0x3F),
      ];
    }
    return [
      0xF0 | (rune >> 18),
      0x80 | ((rune >> 12) & 0x3F),
      0x80 | ((rune >> 6) & 0x3F),
      0x80 | (rune & 0x3F),
    ];
  }

  // ---- subset rejections -----------------------------------------------------

  int _angleAt(int pos) {
    final rest = src.substring(pos);
    final html =
        _htmlOpenTag.firstMatch(rest) ??
        _htmlCloseTag.firstMatch(rest) ??
        _htmlComment.firstMatch(rest) ??
        _htmlProcessingInstruction.firstMatch(rest) ??
        _htmlDeclaration.firstMatch(rest) ??
        _htmlCdata.firstMatch(rest);
    if (html != null) {
      throw const SourceParseException('raw_html');
    }
    if (_uriAutolink.hasMatch(rest) || _emailAutolink.hasMatch(rest)) {
      throw const SourceParseException('autolink');
    }
    _pushText('<');
    return pos + 1;
  }

  int _ampersandAt(int pos) {
    if (_entity.hasMatch(src.substring(pos))) {
      throw const SourceParseException('html_entity');
    }
    _pushText('&');
    return pos + 1;
  }

  // ---- emphasis processing ------------------------------------------------------

  void _processEmphasis(int stackBottom) {
    var closerIndex = stackBottom + 1;
    while (closerIndex < delims.length) {
      final closer = delims[closerIndex];
      if (!closer.active ||
          closer.isBracket ||
          !closer.canClose ||
          closer.count <= 0) {
        closerIndex += 1;
        continue;
      }
      var openerIndex = -1;
      for (var i = closerIndex - 1; i > stackBottom; i--) {
        final opener = delims[i];
        if (!opener.active ||
            opener.isBracket ||
            opener.marker != closer.marker ||
            !opener.canOpen ||
            opener.count <= 0) {
          continue;
        }
        if (closer.marker != 0x7E &&
            (opener.canClose || closer.canOpen) &&
            (opener.origRunLength + closer.origRunLength) % 3 == 0 &&
            !(opener.origRunLength % 3 == 0 && closer.origRunLength % 3 == 0)) {
          continue;
        }
        openerIndex = i;
        break;
      }

      if (openerIndex < 0) {
        if (!closer.canOpen) closer.active = false;
        closerIndex += 1;
        continue;
      }

      final opener = delims[openerIndex];
      final use = closer.marker == 0x7E
          ? 2
          : (opener.count >= 2 && closer.count >= 2 ? 2 : 1);

      var openerTokenIndex = tokens.indexOf(opener.token);
      var closerTokenIndex = tokens.indexOf(closer.token);

      var openInsertAt = openerTokenIndex + 1;
      final openerLeftover = closer.marker == 0x2A
          ? '*' * (opener.count - use)
          : closer.marker == 0x5F
          ? '_' * (opener.count - use)
          : '~' * (opener.count - use);
      if (openerLeftover.isEmpty) {
        tokens.removeAt(openerTokenIndex);
        openInsertAt = openerTokenIndex;
        closerTokenIndex -= 1;
      } else {
        opener.token.content = openerLeftover;
      }

      var closeInsertAt = closerTokenIndex;
      final closerLeftover = closer.marker == 0x2A
          ? '*' * (closer.count - use)
          : closer.marker == 0x5F
          ? '_' * (closer.count - use)
          : '~' * (closer.count - use);
      if (closerLeftover.isEmpty) {
        tokens.removeAt(closeInsertAt);
      } else {
        closer.token.content = closerLeftover;
      }

      final String openType;
      final String closeType;
      if (closer.marker == 0x7E) {
        openType = 's_open';
        closeType = 's_close';
      } else if (use == 2) {
        openType = 'strong_open';
        closeType = 'strong_close';
      } else {
        openType = 'em_open';
        closeType = 'em_close';
      }
      tokens.insert(openInsertAt, InlineToken(openType));
      if (openInsertAt <= closeInsertAt) closeInsertAt += 1;
      tokens.insert(closeInsertAt, InlineToken(closeType));

      opener.count -= use;
      closer.count -= use;
      if (opener.count <= 0) opener.active = false;
      if (closer.count <= 0) {
        closer.active = false;
        closerIndex += 1;
      }
    }
  }
}
