/// Block rules ported from markdown-it (CommonMark + table), the ground truth
/// the PC parser builds on (contracts/source/v1). Every function mirrors its
/// markdown_it/rules_block counterpart; deviations are marked inline. The
/// `reference` and `html_block`/`html_inline` rules implement the frozen
/// mobile subset by rejecting (see contracts/source/v1 README).
library;

import '../../domain/source_parse_error.dart';
import 'md_state.dart';

typedef BlockRule =
    bool Function(MdBlockState state, int startLine, int endLine);

bool _isSpaceChar(int codeUnit) => codeUnit == 0x20 || codeUnit == 0x09;

// ---------------------------------------------------------------------------
// hr

bool _hrRule(MdBlockState state, int startLine, int endLine) {
  var pos = state.bMarks[startLine] + state.tShift[startLine];
  final maximum = state.eMarks[startLine];

  if (state.isCodeBlock(startLine)) return false;

  if (pos >= maximum) return false;
  final marker = state.src.codeUnitAt(pos);
  pos += 1;

  if (marker != 0x2A && marker != 0x2D && marker != 0x5F) return false;

  var count = 1;
  while (pos < maximum) {
    final ch = state.src.codeUnitAt(pos);
    pos += 1;
    if (ch != marker && !_isSpaceChar(ch)) return false;
    if (ch == marker) count += 1;
  }
  if (count < 3) return false;

  state.line = startLine + 1;
  state.push('hr');
  return true;
}

// ---------------------------------------------------------------------------
// ATX heading

bool _headingRule(MdBlockState state, int startLine, int endLine) {
  var pos = state.bMarks[startLine] + state.tShift[startLine];
  var maximum = state.eMarks[startLine];

  if (state.isCodeBlock(startLine)) return false;

  if (pos >= maximum || state.src.codeUnitAt(pos) != 0x23) return false;

  var level = 1;
  pos += 1;
  while (pos < maximum && level <= 6 && state.src.codeUnitAt(pos) == 0x23) {
    level += 1;
    pos += 1;
  }
  if (level > 6) return false;
  if (pos < maximum && !_isSpaceChar(state.src.codeUnitAt(pos))) return false;

  // Cut tails like '    ###  ' from the end of the string.
  maximum = _skipSpacesBack(state, maximum, pos);
  final tmp = _skipCharsBack(state, maximum, 0x23, pos);
  if (tmp > pos && _isSpaceChar(state.src.codeUnitAt(tmp - 1))) {
    maximum = tmp;
  }

  state.line = startLine + 1;
  state.push('heading_open', info: '$level');
  final inline = state.push('inline');
  inline.content = state.src.substring(pos, maximum).trim();
  state.push('heading_close');
  return true;
}

int _skipSpacesBack(MdBlockState state, int pos, int from) {
  while (pos > from && state.src.codeUnitAt(pos - 1) == 0x20) {
    pos -= 1;
  }
  return pos;
}

int _skipCharsBack(MdBlockState state, int pos, int codeUnit, int from) {
  while (pos > from && state.src.codeUnitAt(pos - 1) == codeUnit) {
    pos -= 1;
  }
  return pos;
}

// ---------------------------------------------------------------------------
// indented code

bool _codeRule(MdBlockState state, int startLine, int endLine) {
  if (!state.isCodeBlock(startLine)) return false;

  var last = startLine + 1;
  var nextLine = startLine + 1;
  while (nextLine < endLine) {
    if (state.isEmpty(nextLine)) {
      nextLine += 1;
      continue;
    }
    if (state.isCodeBlock(nextLine)) {
      nextLine += 1;
      last = nextLine;
      continue;
    }
    break;
  }
  state.line = last;
  final token = state.push('code_block');
  token.content =
      '${state.getLines(startLine, last, 4 + state.blkIndent, false)}\n';
  return true;
}

// ---------------------------------------------------------------------------
// fence

bool _fenceRule(MdBlockState state, int startLine, int endLine) {
  var haveEndMarker = false;
  var pos = state.bMarks[startLine] + state.tShift[startLine];
  var maximum = state.eMarks[startLine];

  if (state.isCodeBlock(startLine)) return false;
  if (pos + 3 > maximum) return false;

  final marker = state.src.codeUnitAt(pos);
  if (marker != 0x7E && marker != 0x60) return false;

  final mem = pos;
  pos = state.skipCharsStr(pos, marker);
  final length = pos - mem;
  if (length < 3) return false;

  final params = state.src.substring(pos, maximum);
  if (marker == 0x60 && params.contains('`')) return false;

  var nextLine = startLine;
  while (true) {
    nextLine += 1;
    if (nextLine >= endLine) break;

    var candidateMem = state.bMarks[nextLine] + state.tShift[nextLine];
    pos = candidateMem;
    maximum = state.eMarks[nextLine];

    if (pos < maximum && state.sCount[nextLine] < state.blkIndent) {
      break;
    }
    if (pos >= maximum || state.src.codeUnitAt(pos) != marker) continue;
    if (state.isCodeBlock(nextLine)) continue;

    pos = state.skipCharsStr(pos, marker);
    if (pos - candidateMem < length) continue;
    pos = state.skipSpaces(pos);
    if (pos < maximum) continue;

    haveEndMarker = true;
    break;
  }

  final indent = state.sCount[startLine];
  state.line = nextLine + (haveEndMarker ? 1 : 0);
  final token = state.push('fence');
  token.info = params;
  token.content = state.getLines(startLine + 1, nextLine, indent, true);
  return true;
}

// ---------------------------------------------------------------------------
// html block — the frozen subset rejects raw HTML outright.

final RegExp _htmlBlockStart = RegExp(
  r'^ {0,3}<(?:script|pre|textarea|style)(?:\s|>|$)|'
  r'^ {0,3}<!--|'
  r'^ {0,3}<\?|'
  r'^ {0,3}<![A-Z]|'
  r'^ {0,3}<!\[CDATA\[|'
  r'^ {0,3}</?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)'
  r'(?:\s|[/<>]|$)',
);

final RegExp _htmlBlockCompleteTag = RegExp(
  r'^ {0,3}<(?:/[a-zA-Z][^>\s]*|[a-zA-Z][^>\s]*(?:\s[^<>]*?)?)?/?>\s*$',
);

bool _htmlBlockWouldMatch(MdBlockState state, int startLine) {
  final line = state.getLine(startLine);
  if (line.isEmpty) return false;
  if (_htmlBlockStart.hasMatch(line) || _htmlBlockCompleteTag.hasMatch(line)) {
    return true;
  }
  return false;
}

bool _htmlBlockRule(MdBlockState state, int startLine, int endLine) {
  if (!_htmlBlockWouldMatch(state, startLine)) return false;
  throw SourceParseException('raw_html', ' (line ${startLine + 1})');
}

// ---------------------------------------------------------------------------
// link reference definitions — mobile subset rejects.

final RegExp _referenceDefinition = RegExp(
  r'^ {0,3}\[(?!\s)\S[^\[\]\n]{0,998}\]:\s*(?:[^\s\[]|$)',
);

bool _referenceWouldMatch(MdBlockState state, int startLine) =>
    _referenceDefinition.hasMatch(state.getLine(startLine));

bool _referenceRule(MdBlockState state, int startLine, int endLine) {
  if (!_referenceWouldMatch(state, startLine)) return false;
  throw const SourceParseException('link_reference_definition');
}

// ---------------------------------------------------------------------------
// blockquote

bool _blockquoteRule(MdBlockState state, int startLine, int endLine) {
  final oldLineMax = state.lineMax;
  var pos = state.bMarks[startLine] + state.tShift[startLine];
  var maximum = state.eMarks[startLine];

  if (state.isCodeBlock(startLine)) return false;

  if (pos >= maximum || state.src.codeUnitAt(pos) != 0x3E) return false;
  pos += 1;

  var initial = state.sCount[startLine] + 1;
  var offset = initial;
  var adjustTab = false;
  var spaceAfterMarker = false;

  if (pos < maximum) {
    final secondChar = state.src.codeUnitAt(pos);
    if (secondChar == 0x20) {
      pos += 1;
      initial += 1;
      offset += 1;
      adjustTab = false;
      spaceAfterMarker = true;
    } else if (secondChar == 0x09) {
      spaceAfterMarker = true;
      if ((state.bsCount[startLine] + offset) % 4 == 3) {
        pos += 1;
        initial += 1;
        offset += 1;
        adjustTab = false;
      } else {
        adjustTab = true;
      }
    }
  }

  final oldBMarks = <int>[];
  final oldBSCount = <int>[];
  final oldSCount = <int>[];
  final oldTShift = <int>[];

  oldBMarks.add(state.bMarks[startLine]);
  state.bMarks[startLine] = pos;

  while (pos < maximum) {
    final ch = state.src.codeUnitAt(pos);
    if (!_isSpaceChar(ch)) break;
    if (ch == 0x09) {
      offset +=
          4 - (offset + state.bsCount[startLine] + (adjustTab ? 1 : 0)) % 4;
    } else {
      offset += 1;
    }
    pos += 1;
  }

  oldBSCount.add(state.bsCount[startLine]);
  state.bsCount[startLine] =
      state.sCount[startLine] + 1 + (spaceAfterMarker ? 1 : 0);

  var lastLineEmpty = pos >= maximum;

  oldSCount.add(state.sCount[startLine]);
  state.sCount[startLine] = offset - initial;

  oldTShift.add(state.tShift[startLine]);
  state.tShift[startLine] = pos - state.bMarks[startLine];

  final terminatorRules = blockquoteTerminators;

  final oldParentType = state.parentType;
  state.parentType = 'blockquote';

  var nextLine = startLine + 1;
  while (nextLine < endLine) {
    final isOutdented = state.sCount[nextLine] < state.blkIndent;

    pos = state.bMarks[nextLine] + state.tShift[nextLine];
    maximum = state.eMarks[nextLine];

    if (pos >= maximum) break;

    final evaluatesTrue = state.src.codeUnitAt(pos) == 0x3E && !isOutdented;
    pos += 1;
    if (evaluatesTrue) {
      initial = offset = state.sCount[nextLine] + 1;

      if (pos < maximum) {
        final nextChar = state.src.codeUnitAt(pos);
        if (nextChar == 0x20) {
          pos += 1;
          initial += 1;
          offset += 1;
          adjustTab = false;
          spaceAfterMarker = true;
        } else if (nextChar == 0x09) {
          spaceAfterMarker = true;
          if ((state.bsCount[nextLine] + offset) % 4 == 3) {
            pos += 1;
            initial += 1;
            offset += 1;
            adjustTab = false;
          } else {
            adjustTab = true;
          }
        } else {
          spaceAfterMarker = false;
        }
      } else {
        spaceAfterMarker = false;
      }

      oldBMarks.add(state.bMarks[nextLine]);
      state.bMarks[nextLine] = pos;

      while (pos < maximum) {
        final ch = state.src.codeUnitAt(pos);
        if (!_isSpaceChar(ch)) break;
        if (ch == 0x09) {
          offset +=
              4 - (offset + state.bsCount[nextLine] + (adjustTab ? 1 : 0)) % 4;
        } else {
          offset += 1;
        }
        pos += 1;
      }

      lastLineEmpty = pos >= maximum;

      oldBSCount.add(state.bsCount[nextLine]);
      state.bsCount[nextLine] =
          state.sCount[nextLine] + 1 + (spaceAfterMarker ? 1 : 0);

      oldSCount.add(state.sCount[nextLine]);
      state.sCount[nextLine] = offset - initial;

      oldTShift.add(state.tShift[nextLine]);
      state.tShift[nextLine] = pos - state.bMarks[nextLine];

      nextLine += 1;
      continue;
    }

    if (lastLineEmpty) break;

    var terminate = false;
    for (final rule in terminatorRules) {
      if (rule(state, nextLine, endLine)) {
        terminate = true;
        break;
      }
    }

    if (terminate) {
      state.lineMax = nextLine;
      if (state.blkIndent != 0) {
        oldBMarks.add(state.bMarks[nextLine]);
        oldBSCount.add(state.bsCount[nextLine]);
        oldTShift.add(state.tShift[nextLine]);
        oldSCount.add(state.sCount[nextLine]);
        state.sCount[nextLine] -= state.blkIndent;
      }
      break;
    }

    oldBMarks.add(state.bMarks[nextLine]);
    oldBSCount.add(state.bsCount[nextLine]);
    oldTShift.add(state.tShift[nextLine]);
    oldSCount.add(state.sCount[nextLine]);

    // Negative indentation marks a lazy paragraph continuation.
    state.sCount[nextLine] = -1;

    nextLine += 1;
  }

  final oldIndent = state.blkIndent;
  state.blkIndent = 0;

  state.push('blockquote_open');
  tokenize(state, startLine, nextLine);
  state.push('blockquote_close');

  state.lineMax = oldLineMax;
  state.parentType = oldParentType;

  for (var i = 0; i < oldTShift.length; i++) {
    state.bMarks[startLine + i] = oldBMarks[i];
    state.tShift[startLine + i] = oldTShift[i];
    state.sCount[startLine + i] = oldSCount[i];
    state.bsCount[startLine + i] = oldBSCount[i];
  }
  state.blkIndent = oldIndent;

  return true;
}

// ---------------------------------------------------------------------------
// lists

(int, bool, int)? _skipOrderedListMarker(MdBlockState state, int line) {
  final start = state.bMarks[line] + state.tShift[line];
  var pos = start;
  final maximum = state.eMarks[line];

  if (pos + 1 >= maximum) return null;
  var ch = state.src.codeUnitAt(pos);
  pos += 1;
  if (ch < 0x30 || ch > 0x39) return null;

  while (true) {
    if (pos >= maximum) return null;
    ch = state.src.codeUnitAt(pos);
    pos += 1;
    if (ch >= 0x30 && ch <= 0x39) {
      if (pos - start >= 10) return null;
      continue;
    }
    if (ch == 0x29 || ch == 0x2E) break;
    return null;
  }

  if (pos < maximum && !_isSpaceChar(state.src.codeUnitAt(pos))) return null;
  return (pos, true, int.parse(state.src.substring(start, pos - 1)));
}

(int, bool, int)? _skipBulletListMarker(MdBlockState state, int line) {
  var pos = state.bMarks[line] + state.tShift[line];
  final maximum = state.eMarks[line];

  if (pos >= maximum) return null;
  final marker = state.src.codeUnitAt(pos);
  pos += 1;
  if (marker != 0x2A && marker != 0x2D && marker != 0x2B) return null;
  if (pos < maximum && !_isSpaceChar(state.src.codeUnitAt(pos))) return null;
  return (pos, false, 0);
}

bool _listRule(MdBlockState state, int startLine, int endLine) {
  var isTerminatingParagraph = false;

  if (state.isCodeBlock(startLine)) return false;

  if (state.listIndent >= 0 &&
      state.sCount[startLine] - state.listIndent >= 4 &&
      state.sCount[startLine] < state.blkIndent) {
    return false;
  }

  if (state.parentType == 'paragraph' &&
      state.sCount[startLine] >= state.blkIndent) {
    isTerminatingParagraph = true;
  }

  var markerScan = _skipOrderedListMarker(state, startLine);
  final isOrdered = markerScan != null;
  var posAfterMarker = markerScan?.$1 ?? -1;
  if (markerScan == null) {
    markerScan = _skipBulletListMarker(state, startLine);
    posAfterMarker = markerScan?.$1 ?? -1;
    if (markerScan == null) return false;
  } else if (isTerminatingParagraph && markerScan.$3 != 1) {
    return false;
  }

  if (isTerminatingParagraph &&
      state.skipSpaces(posAfterMarker) >= state.eMarks[startLine]) {
    return false;
  }

  final markerChar = state.src.codeUnitAt(posAfterMarker - 1);

  state.push(isOrdered ? 'ordered_list_open' : 'bullet_list_open');

  var nextLine = startLine;
  final terminatorRules = listTerminators;

  final oldParentType = state.parentType;
  state.parentType = 'list';

  while (nextLine < endLine) {
    var pos = posAfterMarker;
    var maximum = state.eMarks[nextLine];

    final markerStart = state.bMarks[startLine] + state.tShift[startLine];
    final initial = state.sCount[nextLine] + posAfterMarker - markerStart;
    var offset = initial;

    while (pos < maximum) {
      final ch = state.src.codeUnitAt(pos);
      if (ch == 0x09) {
        offset += 4 - (offset + state.bsCount[nextLine]) % 4;
      } else if (ch == 0x20) {
        offset += 1;
      } else {
        break;
      }
      pos += 1;
    }

    final contentStart = pos;

    var indentAfterMarker = contentStart >= maximum ? 1 : offset - initial;
    if (indentAfterMarker > 4) indentAfterMarker = 1;
    final indent = initial + indentAfterMarker;

    final itemToken = state.push('list_item_open');
    if (isOrdered) {
      itemToken.info = state.src.substring(markerStart, posAfterMarker - 1);
    }

    final oldListIndent = state.listIndent;
    final oldBMark = state.bMarks[startLine];
    final oldTShift = state.tShift[startLine];
    final oldSCount = state.sCount[startLine];

    state.listIndent = state.blkIndent;
    state.blkIndent = indent;

    state.tShift[startLine] = contentStart - state.bMarks[startLine];
    state.sCount[startLine] = offset;

    if (contentStart >= maximum &&
        startLine + 1 < endLine &&
        state.isEmpty(startLine + 1)) {
      // An empty list item whose list ends before the next block.
      state.line = (state.line + 2) < endLine ? state.line + 2 : endLine;
    } else {
      tokenize(state, startLine, endLine);
    }

    state.blkIndent = state.listIndent;
    state.listIndent = oldListIndent;
    state.bMarks[startLine] = oldBMark;
    state.tShift[startLine] = oldTShift;
    state.sCount[startLine] = oldSCount;

    state.push('list_item_close');

    nextLine = startLine = state.line;
    if (nextLine >= endLine) break;

    if (state.sCount[nextLine] < state.blkIndent) break;
    if (state.isCodeBlock(startLine)) break;

    var terminate = false;
    for (final rule in terminatorRules) {
      if (rule(state, nextLine, endLine)) {
        terminate = true;
        break;
      }
    }
    if (terminate) break;

    if (isOrdered) {
      final scan = _skipOrderedListMarker(state, nextLine);
      if (scan == null) break;
      posAfterMarker = scan.$1;
    } else {
      final scan = _skipBulletListMarker(state, nextLine);
      if (scan == null) break;
      posAfterMarker = scan.$1;
    }
    if (markerChar != state.src.codeUnitAt(posAfterMarker - 1)) break;
  }

  state.push(isOrdered ? 'ordered_list_close' : 'bullet_list_close');
  state.line = nextLine;
  state.parentType = oldParentType;
  // prevEmptyEnd feeds the tight/loose flag, which the PC walk ignores.
  // (intentionally no tight handling)
  return true;
}

// ---------------------------------------------------------------------------
// tables (GFM)

const _maxAutocompletedCells = 0x10000;

/// Split a table row on unescaped pipes; `\|` keeps the pipe.
List<String> _escapedSplitEscaped(String string) {
  final result = <String>[];
  var pos = 0;
  final max = string.length;
  var isEscaped = false;
  var lastPos = 0;
  var current = '';
  while (pos < max) {
    final ch = string.codeUnitAt(pos);
    if (ch == 0x7C) {
      if (!isEscaped) {
        result.add(current + string.substring(lastPos, pos));
        current = '';
        lastPos = pos + 1;
      } else {
        current += string.substring(lastPos, pos - 1);
        lastPos = pos;
      }
    }
    isEscaped = ch == 0x5C;
    pos += 1;
  }
  result.add(current + string.substring(lastPos));
  return result;
}

final RegExp _headerLineRe = RegExp(r'^:?-+:?$');

bool _tableRule(MdBlockState state, int startLine, int endLine) {
  if (startLine + 2 > endLine) return false;

  var nextLine = startLine + 1;

  if (state.sCount[nextLine] < state.blkIndent) return false;
  if (state.isCodeBlock(nextLine)) return false;

  var pos = state.bMarks[nextLine] + state.tShift[nextLine];
  if (pos >= state.eMarks[nextLine]) return false;
  var firstCh = state.src.codeUnitAt(pos);
  pos += 1;
  if (firstCh != 0x7C && firstCh != 0x2D && firstCh != 0x3A) return false;
  if (pos >= state.eMarks[nextLine]) return false;
  final secondCh = state.src.codeUnitAt(pos);
  pos += 1;
  if (secondCh != 0x7C &&
      secondCh != 0x2D &&
      secondCh != 0x3A &&
      !_isSpaceChar(secondCh)) {
    return false;
  }
  if (firstCh == 0x2D && _isSpaceChar(secondCh)) return false;

  while (pos < state.eMarks[nextLine]) {
    final ch = state.src.codeUnitAt(pos);
    if (ch != 0x7C && ch != 0x2D && ch != 0x3A && !_isSpaceChar(ch)) {
      return false;
    }
    pos += 1;
  }

  final lineText = state.getLine(nextLine);
  final columns = lineText.split('|');
  final aligns = <String>[];
  for (var i = 0; i < columns.length; i++) {
    final t = columns[i].trim();
    if (t.isEmpty) {
      if (i == 0 || i == columns.length - 1) continue;
      return false;
    }
    if (!_headerLineRe.hasMatch(t)) return false;
    if (t.endsWith(':')) {
      aligns.add(t.startsWith(':') ? 'center' : 'right');
    } else if (t.startsWith(':')) {
      aligns.add('left');
    } else {
      aligns.add('');
    }
  }

  final headerText = state.getLine(startLine).trim();
  if (!headerText.contains('|')) return false;
  if (state.isCodeBlock(startLine)) return false;
  var headerColumns = _escapedSplitEscaped(headerText);
  if (headerColumns.isNotEmpty && headerColumns.first == '') {
    headerColumns.removeAt(0);
  }
  if (headerColumns.isNotEmpty && headerColumns.last == '') {
    headerColumns.removeLast();
  }

  final columnCount = headerColumns.length;
  if (columnCount == 0 || columnCount != aligns.length) return false;

  final oldParentType = state.parentType;
  state.parentType = 'table';
  final terminatorRules = blockquoteTerminators;

  state.push('table_open');
  state.push('thead_open');
  state.push('tr_open');
  for (var i = 0; i < columnCount; i++) {
    final th = state.push('th_open');
    if (aligns[i].isNotEmpty) {
      th.attrs = {'style': 'text-align:${aligns[i]}'};
    }
    final inline = state.push('inline');
    inline.content = headerColumns[i].trim();
    state.push('th_close');
  }
  state.push('tr_close');
  state.push('thead_close');

  var autocompletedCells = 0;
  nextLine = startLine + 2;
  var tbodyOpen = false;
  while (nextLine < endLine) {
    if (state.sCount[nextLine] < state.blkIndent) break;

    var terminate = false;
    for (final rule in terminatorRules) {
      if (rule(state, nextLine, endLine)) {
        terminate = true;
        break;
      }
    }
    if (terminate) break;
    final rowText = state.getLine(nextLine).trim();
    if (rowText.isEmpty) break;
    if (state.isCodeBlock(nextLine)) break;
    var rowColumns = _escapedSplitEscaped(rowText);
    if (rowColumns.isNotEmpty && rowColumns.first == '') {
      rowColumns.removeAt(0);
    }
    if (rowColumns.isNotEmpty && rowColumns.last == '') {
      rowColumns.removeLast();
    }
    autocompletedCells += columnCount - rowColumns.length;
    if (autocompletedCells > _maxAutocompletedCells) break;

    if (nextLine == startLine + 2) {
      state.push('tbody_open');
      tbodyOpen = true;
    }

    state.push('tr_open');
    for (var i = 0; i < columnCount; i++) {
      final td = state.push('td_open');
      if (aligns[i].isNotEmpty) {
        td.attrs = {'style': 'text-align:${aligns[i]}'};
      }
      final inline = state.push('inline');
      inline.content = i < rowColumns.length && rowColumns[i].isNotEmpty
          ? rowColumns[i].trim()
          : '';
      state.push('td_close');
    }
    state.push('tr_close');

    nextLine += 1;
  }
  if (tbodyOpen) state.push('tbody_close');
  state.push('table_close');

  state.parentType = oldParentType;
  state.line = nextLine;
  return true;
}

// ---------------------------------------------------------------------------
// setext headings (lheading)

bool _lheadingRule(MdBlockState state, int startLine, int endLine) {
  int? level;
  var nextLine = startLine + 1;
  final terminatorRules = paragraphTerminators;

  if (state.isCodeBlock(startLine)) return false;

  final oldParentType = state.parentType;
  state.parentType = 'paragraph';

  while (nextLine < endLine && !state.isEmpty(nextLine)) {
    if (state.sCount[nextLine] - state.blkIndent > 3) {
      nextLine += 1;
      continue;
    }

    if (state.sCount[nextLine] >= state.blkIndent) {
      final pos = state.bMarks[nextLine] + state.tShift[nextLine];
      final maximum = state.eMarks[nextLine];
      if (pos < maximum) {
        final ch = state.src.codeUnitAt(pos);
        if (ch == 0x2D || ch == 0x3D) {
          var end = state.skipCharsStr(pos, ch);
          end = state.skipSpaces(end);
          if (end >= maximum) {
            level = ch == 0x3D ? 1 : 2;
            break;
          }
        }
      }
    }

    if (state.sCount[nextLine] < 0) {
      nextLine += 1;
      continue;
    }

    var terminate = false;
    for (final rule in terminatorRules) {
      if (rule(state, nextLine, endLine)) {
        terminate = true;
        break;
      }
    }
    if (terminate) break;
    nextLine += 1;
  }

  if (level == null) {
    state.parentType = oldParentType;
    return false;
  }

  final content = state
      .getLines(startLine, nextLine, state.blkIndent, false)
      .trim();

  state.line = nextLine + 1;
  state.push('heading_open', info: '$level');
  final inline = state.push('inline');
  inline.content = content;
  state.push('heading_close');
  state.parentType = oldParentType;
  return true;
}

// ---------------------------------------------------------------------------
// paragraph

bool _paragraphRule(MdBlockState state, int startLine, int endLine) {
  var nextLine = startLine + 1;
  final terminatorRules = paragraphTerminators;
  endLine = state.lineMax;

  final oldParentType = state.parentType;
  state.parentType = 'paragraph';

  while (nextLine < endLine) {
    if (state.isEmpty(nextLine)) break;
    if (state.sCount[nextLine] - state.blkIndent > 3) {
      nextLine += 1;
      continue;
    }
    if (state.sCount[nextLine] < 0) {
      nextLine += 1;
      continue;
    }

    var terminate = false;
    for (final rule in terminatorRules) {
      if (rule(state, nextLine, endLine)) {
        terminate = true;
        break;
      }
    }
    if (terminate) break;
    nextLine += 1;
  }

  final content = state
      .getLines(startLine, nextLine, state.blkIndent, false)
      .trim();

  state.line = nextLine;
  state.push('paragraph_open');
  final inline = state.push('inline');
  inline.content = content;
  state.push('paragraph_close');
  state.parentType = oldParentType;
  return true;
}

// ---------------------------------------------------------------------------
// rule chains (order matches markdown-it's parser_block._rules)

final List<BlockRule> paragraphTerminators = [
  _tableDetect,
  _fenceDetect,
  _blockquoteDetect,
  _hrDetect,
  _listDetect,
  _htmlBlockDetect,
  _headingDetect,
];

final List<BlockRule> blockquoteTerminators = [
  _fenceDetect,
  _blockquoteDetect,
  _hrDetect,
  _listDetect,
  _htmlBlockDetect,
  _headingDetect,
];

final List<BlockRule> listTerminators = [
  _fenceDetect,
  _blockquoteDetect,
  _hrDetect,
];

// Detection-only wrappers (markdown-it's silent mode): they answer "would this
// rule match" without emitting tokens or throwing subset rejections.
bool _tableDetect(MdBlockState state, int line, int endLine) =>
    _tableMatches(state, line, endLine);

bool _tableMatches(MdBlockState state, int startLine, int endLine) {
  if (startLine + 2 > endLine) return false;
  final nextLine = startLine + 1;
  if (nextLine >= state.lineMax) return false;
  if (state.sCount[nextLine] < state.blkIndent) return false;
  if (state.isCodeBlock(nextLine)) return false;
  final delimiter = state.getLine(nextLine);
  if (delimiter.isEmpty) return false;
  final firstCh = delimiter.codeUnitAt(0);
  if (firstCh != 0x7C && firstCh != 0x2D && firstCh != 0x3A) return false;
  if (delimiter.length > 1) {
    final secondCh = delimiter.codeUnitAt(1);
    if (firstCh == 0x2D && _isSpaceChar(secondCh)) return false;
  }
  for (final ch in delimiter.codeUnits) {
    if (ch != 0x7C && ch != 0x2D && ch != 0x3A && !_isSpaceChar(ch)) {
      return false;
    }
  }
  if (!state.getLine(startLine).contains('|')) return false;
  if (state.isCodeBlock(startLine)) return false;
  // Column counts must agree; reuse the full parser's split logic.
  final columns = delimiter.split('|');
  var alignCount = 0;
  for (var i = 0; i < columns.length; i++) {
    final t = columns[i].trim();
    if (t.isEmpty) {
      if (i == 0 || i == columns.length - 1) continue;
      return false;
    }
    if (!_headerLineRe.hasMatch(t)) return false;
    alignCount += 1;
  }
  var headerColumns = _escapedSplitEscaped(state.getLine(startLine).trim());
  if (headerColumns.isNotEmpty && headerColumns.first == '') {
    headerColumns.removeAt(0);
  }
  if (headerColumns.isNotEmpty && headerColumns.last == '') {
    headerColumns.removeLast();
  }
  return headerColumns.isNotEmpty && headerColumns.length == alignCount;
}

bool _fenceDetect(MdBlockState state, int line, int endLine) {
  var pos = state.bMarks[line] + state.tShift[line];
  final maximum = state.eMarks[line];
  if (state.isCodeBlock(line)) return false;
  if (pos + 3 > maximum) return false;
  final marker = state.src.codeUnitAt(pos);
  if (marker != 0x7E && marker != 0x60) return false;
  final mem = pos;
  pos = state.skipCharsStr(pos, marker);
  if (pos - mem < 3) return false;
  if (marker == 0x60 && state.src.substring(pos, maximum).contains('`')) {
    return false;
  }
  return true;
}

bool _blockquoteDetect(MdBlockState state, int line, int endLine) {
  if (state.isCodeBlock(line)) return false;
  final pos = state.bMarks[line] + state.tShift[line];
  return pos < state.eMarks[line] && state.src.codeUnitAt(pos) == 0x3E;
}

bool _hrDetect(MdBlockState state, int line, int endLine) {
  var pos = state.bMarks[line] + state.tShift[line];
  final maximum = state.eMarks[line];
  if (state.isCodeBlock(line)) return false;
  if (pos >= maximum) return false;
  final marker = state.src.codeUnitAt(pos);
  if (marker != 0x2A && marker != 0x2D && marker != 0x5F) return false;
  var count = 1;
  pos += 1;
  while (pos < maximum) {
    final ch = state.src.codeUnitAt(pos);
    pos += 1;
    if (ch != marker && !_isSpaceChar(ch)) return false;
    if (ch == marker) count += 1;
  }
  return count >= 3;
}

bool _listDetect(MdBlockState state, int line, int endLine) {
  if (state.isCodeBlock(line)) return false;

  if (state.listIndent >= 0 &&
      state.sCount[line] - state.listIndent >= 4 &&
      state.sCount[line] < state.blkIndent) {
    return false;
  }
  final isTerminatingParagraph =
      state.parentType == 'paragraph' && state.sCount[line] >= state.blkIndent;

  var scan = _skipOrderedListMarker(state, line);
  if (scan != null) {
    if (isTerminatingParagraph && scan.$3 != 1) return false;
  } else {
    scan = _skipBulletListMarker(state, line);
    if (scan == null) return false;
  }
  if (isTerminatingParagraph &&
      state.skipSpaces(scan.$1) >= state.eMarks[line]) {
    return false;
  }
  return true;
}

bool _htmlBlockDetect(MdBlockState state, int line, int endLine) =>
    _htmlBlockWouldMatch(state, line);

bool _headingDetect(MdBlockState state, int line, int endLine) {
  var pos = state.bMarks[line] + state.tShift[line];
  final maximum = state.eMarks[line];
  if (state.isCodeBlock(line)) return false;
  if (pos >= maximum || state.src.codeUnitAt(pos) != 0x23) return false;
  var level = 1;
  pos += 1;
  while (pos < maximum && level <= 6 && state.src.codeUnitAt(pos) == 0x23) {
    level += 1;
    pos += 1;
  }
  if (level > 6) return false;
  if (pos < maximum && !_isSpaceChar(state.src.codeUnitAt(pos))) return false;
  return true;
}

final List<BlockRule> blockChain = [
  _tableRule,
  _codeRule,
  _fenceRule,
  _blockquoteRule,
  _hrRule,
  _listRule,
  _referenceRule,
  _htmlBlockRule,
  _headingRule,
  _lheadingRule,
  _paragraphRule,
];

/// The tokenize loop (parser_block.tokenize): skips empty lines, breaks on
/// nested-call outdents, then tries each rule until one consumes lines.
void tokenize(MdBlockState state, int startLine, int endLine) {
  var line = startLine;
  while (line < endLine) {
    line = skipEmptyLines(state, line);
    if (line >= endLine) break;
    // Termination condition for nested calls (blockquotes & lists).
    if (state.sCount[line] < state.blkIndent) break;

    state.line = line;
    var matched = false;
    for (final rule in blockChain) {
      if (rule(state, line, endLine)) {
        matched = true;
        break;
      }
    }
    if (!matched) break;
    final previous = line;
    line = state.line;
    if (line <= previous) break; // defensive: no rule may stall the cursor
  }
}

int skipEmptyLines(MdBlockState state, int from) {
  var line = from;
  final max = state.lineMax;
  while (line < max && state.isEmpty(line)) {
    line += 1;
  }
  return line;
}
