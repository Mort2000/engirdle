/// A faithful port of markdown-it's block state machine (StateBlock): the
/// per-line offset caches, container indent bookkeeping and the tokenize loop
/// that drives the block rules. Ported line-for-line from
/// markdown_it/rules_block/state_block.py so the Dart parser shares markdown-it
/// (and therefore PC `engirdle-gfm@1`) behavior; see contracts/source/v1.
library;

/// A stream inline token: types match markdown-it names (`text`,
/// `code_inline`, `softbreak`, `hardbreak`, `em_open`… `link_open`, `image`,
/// `html_inline`).
class InlineToken {
  InlineToken(this.type, {this.content = '', this.attrs, this.children});

  final String type;
  String content;
  Map<String, String>? attrs;
  List<InlineToken>? children;
}

/// A block-level token (flat stream, paired open/close like markdown-it).
class BlockToken {
  BlockToken(this.type, {this.content = '', this.info, this.attrs});

  final String type;

  /// fence/code body; inline token content lives in [children].
  String content;

  /// list_item_open: the literal ordinal digits; fence: the info string.
  String? info;

  Map<String, String>? attrs;
  List<InlineToken>? children;
}

class MdBlockState {
  MdBlockState(this.src) {
    _buildLineCaches();
  }

  final String src;

  final List<int> bMarks = [];
  final List<int> eMarks = [];
  final List<int> tShift = [];
  final List<int> sCount = [];
  final List<int> bsCount = [];

  int blkIndent = 0;
  int line = 0;
  int lineMax = 0;
  int listIndent = -1;

  /// 'root' | 'paragraph' | 'list' | 'blockquote' — mirrors markdown-it's
  /// parentType used by interrupt rules.
  String parentType = 'root';

  final List<BlockToken> tokens = [];

  void _buildLineCaches() {
    var indentFound = false;
    var start = 0, pos = 0, indent = 0, offset = 0;
    final length = src.length;
    if (length == 0) {
      _pushFake();
      lineMax = 0;
      return;
    }
    for (pos = 0; pos < length; pos++) {
      final ch = src.codeUnitAt(pos);
      if (!indentFound) {
        if (ch == 0x20 || ch == 0x09) {
          indent += 1;
          offset += ch == 0x09 ? 4 - offset % 4 : 1;
          continue;
        }
        indentFound = true;
      }
      if (ch == 0x0A || pos == length - 1) {
        final end = ch == 0x0A ? pos : pos + 1;
        bMarks.add(start);
        eMarks.add(end);
        tShift.add(indent);
        sCount.add(offset);
        bsCount.add(0);
        indentFound = false;
        indent = 0;
        offset = 0;
        start = end + 1;
      }
    }
    _pushFake();
    lineMax = bMarks.length - 1;
  }

  void _pushFake() {
    bMarks.add(src.length);
    eMarks.add(src.length);
    tShift.add(0);
    sCount.add(0);
    bsCount.add(0);
  }

  bool isEmpty(int line) => bMarks[line] + tShift[line] >= eMarks[line];

  bool isCodeBlock(int line) => sCount[line] - blkIndent >= 4;

  BlockToken push(String type, {String content = '', String? info}) {
    final token = BlockToken(type, content: content, info: info);
    tokens.add(token);
    return token;
  }

  int skipSpaces(int pos) {
    while (pos < src.length && (src.codeUnitAt(pos) == 0x20)) {
      pos += 1;
    }
    return pos;
  }

  int skipCharsStr(int pos, int codeUnit) {
    while (pos < src.length && src.codeUnitAt(pos) == codeUnit) {
      pos += 1;
    }
    return pos;
  }

  /// Cut lines range, expanding tabs up to [indent] virtual columns.
  String getLines(int begin, int end, int indent, bool keepLastLf) {
    var line = begin;
    if (begin >= end) return '';
    final queue = List.filled(end - begin, '');

    var i = 1;
    while (line < end) {
      var lineIndent = 0;
      final lineStart = bMarks[line];
      var first = lineStart;
      var last = line + 1 < end || keepLastLf ? eMarks[line] + 1 : eMarks[line];

      while (first < last && lineIndent < indent) {
        final ch = src.codeUnitAt(first);
        if (ch == 0x20) {
          lineIndent += 1;
        } else if (ch == 0x09) {
          lineIndent += 4 - (lineIndent + bsCount[line]) % 4;
        } else if (first - lineStart < tShift[line]) {
          lineIndent += 1;
        } else {
          break;
        }
        first += 1;
      }

      if (lineIndent > indent) {
        queue[i - 1] = ' ' * (lineIndent - indent) + src.substring(first, last);
      } else {
        queue[i - 1] = src.substring(first, last);
      }
      line += 1;
      i += 1;
    }
    return queue.join();
  }

  String getLine(int line) {
    final pos = bMarks[line] + tShift[line];
    return src.substring(pos, eMarks[line]);
  }
}
