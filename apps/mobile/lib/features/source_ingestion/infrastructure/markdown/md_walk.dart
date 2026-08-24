/// A verbatim port of the PC token walk (`markdown.py: _parse_tokens` and
/// friends): flat block tokens → the typed ParsedBlock union with sequential
/// `block-N`/`sentence-N`/`cell-{b}-{i}` IDs, resource limits and warnings.
/// Allocation order is load-bearing (nested constructs allocate before their
/// parents), so this file follows the Python control flow statement by
/// statement.
library;

import '../../../../contracts/readpack_v1/article.dart';
import '../../domain/source_parse_error.dart';
import '../segmenter.dart';
import '../unicode_text.dart';
import 'md_state.dart';
import 'markdown_limits.dart';

class _Cursor {
  int blockNumber = 0;
  int sentenceNumber = 0;

  String nextBlockId() => 'block-${++blockNumber}';
  String nextSentenceId() => 'sentence-${++sentenceNumber}';
  int get blockIndex => blockNumber;
}

class _WalkInline {
  String text = '';
  List<ArticleRun> runs = [];
}

const _stylePriority = <String, int>{
  'code': 6,
  'image': 5,
  'link': 4,
  'strong': 3,
  'emphasis': 2,
  'strikethrough': 1,
};

/// Walks the token stream into typed blocks. [inlineChildren] supplies the
/// parsed inline token children for every `inline` block token.
List<ParsedBlock> walkTokens({
  required List<BlockToken> tokens,
  required List<InlineToken> Function(BlockToken token) childrenOf,
  required MarkdownLimits limits,
  required List<SourceParseWarning> warnings,
}) {
  final cursor = _Cursor();
  final blocks = _parseTokens(
    tokens,
    0,
    tokens.length,
    cursor,
    limits,
    warnings,
    childrenOf: childrenOf,
    quoteDepth: 0,
    listDepth: 0,
  );
  return [for (var i = 0; i < blocks.length; i++) _withOrder(blocks[i], i)];
}

List<ParsedBlock> _parseTokens(
  List<BlockToken> tokens,
  int start,
  int end,
  _Cursor cursor,
  MarkdownLimits limits,
  List<SourceParseWarning> warnings, {
  required List<InlineToken> Function(BlockToken token) childrenOf,
  required int quoteDepth,
  int listDepth = 0,
}) {
  final blocks = <ParsedBlock>[];
  var index = start;
  while (index < end) {
    final token = tokens[index];
    final blockIndex = cursor.blockIndex + 1;
    switch (token.type) {
      case 'heading_open':
        final inline = _walkInline(
          childrenOf(tokens[index + 1]),
          limits,
          blockIndex,
        );
        blocks.add(
          _textBlock(
            cursor,
            kind: ArticleTextKind.heading,
            inline: inline,
            limits: limits,
            headingLevel: int.parse(token.info ?? '1'),
          ),
        );
        index += 3;
      case 'paragraph_open':
        final inline = _walkInline(
          childrenOf(tokens[index + 1]),
          limits,
          blockIndex,
        );
        if (inline.text.trim().isNotEmpty) {
          blocks.add(
            _textBlock(
              cursor,
              kind: quoteDepth > 0
                  ? ArticleTextKind.quote
                  : ArticleTextKind.paragraph,
              inline: inline,
              limits: limits,
              quoteDepth: quoteDepth,
            ),
          );
        }
        index += 3;
      case 'fence':
        final info = token.info?.trim() ?? '';
        blocks.add(
          _codeBlock(cursor, token.content, info.isEmpty ? null : info, limits),
        );
        index += 1;
      case 'code_block':
        blocks.add(_codeBlock(cursor, token.content, null, limits));
        index += 1;
      case 'hr':
        blocks.add(ParsedDividerBlock(blockId: cursor.nextBlockId(), order: 0));
        index += 1;
      case 'blockquote_open':
        final close = _matchingClose(
          tokens,
          index,
          end,
          'blockquote_open',
          'blockquote_close',
        );
        if (quoteDepth + 1 > limits.maxNestingDepth) {
          throw const SourceParseException('nesting_depth', ' (blockquote)');
        }
        blocks.addAll(
          _parseTokens(
            tokens,
            index + 1,
            close,
            cursor,
            limits,
            warnings,
            childrenOf: childrenOf,
            quoteDepth: quoteDepth + 1,
          ),
        );
        index = close + 1;
      case 'bullet_list_open' || 'ordered_list_open':
        final closeType = token.type.replaceFirst('_open', '_close');
        final close = _matchingClose(tokens, index, end, token.type, closeType);
        blocks.addAll(
          _parseList(
            tokens,
            index + 1,
            close,
            cursor,
            limits,
            warnings,
            childrenOf: childrenOf,
            quoteDepth: quoteDepth,
            listDepth: listDepth,
            ordered: token.type == 'ordered_list_open',
          ),
        );
        index = close + 1;
      case 'table_open':
        final close = _matchingClose(
          tokens,
          index,
          end,
          'table_open',
          'table_close',
        );
        blocks.add(
          _parseTable(
            tokens,
            index + 1,
            close,
            cursor,
            limits,
            blockIndex,
            childrenOf,
          ),
        );
        index = close + 1;
      default:
        // Structural closers and inline payloads are consumed by their
        // opening constructs.
        index += 1;
    }
  }
  return blocks;
}

int _matchingClose(
  List<BlockToken> tokens,
  int openIndex,
  int end,
  String openType,
  String closeType,
) {
  var depth = 0;
  for (var index = openIndex; index < end; index++) {
    final type = tokens[index].type;
    if (type == openType) {
      depth += 1;
    } else if (type == closeType) {
      depth -= 1;
      if (depth == 0) return index;
    }
  }
  throw const SourceParseException('no_blocks', ' (unbalanced structure)');
}

List<ParsedBlock> _parseList(
  List<BlockToken> tokens,
  int start,
  int end,
  _Cursor cursor,
  MarkdownLimits limits,
  List<SourceParseWarning> warnings, {
  required List<InlineToken> Function(BlockToken token) childrenOf,
  required int quoteDepth,
  required int listDepth,
  required bool ordered,
}) {
  final blocks = <ParsedBlock>[];
  final itemDepth = listDepth + 1;
  if (itemDepth > limits.maxNestingDepth) {
    throw const SourceParseException('nesting_depth', ' (list)');
  }
  var index = start;
  while (index < end) {
    final token = tokens[index];
    if (token.type != 'list_item_open') {
      index += 1;
      continue;
    }
    final close = _matchingClose(
      tokens,
      index,
      end,
      'list_item_open',
      'list_item_close',
    );
    final ordinal = ordered && (token.info?.trim().isNotEmpty ?? false)
        ? int.tryParse(token.info!)
        : null;
    final (itemInline, nested) = _listItemContent(
      tokens,
      index + 1,
      close,
      cursor,
      limits,
      warnings,
      childrenOf: childrenOf,
      quoteDepth: quoteDepth,
      itemDepth: itemDepth,
    );
    if (itemInline.text.trim().isNotEmpty) {
      blocks.add(
        _textBlock(
          cursor,
          kind: ArticleTextKind.listItem,
          inline: itemInline,
          limits: limits,
          listKind: ordered ? ArticleListKind.ordered : ArticleListKind.bullet,
          listDepth: itemDepth,
          listOrdinal: ordinal,
        ),
      );
    }
    blocks.addAll(nested);
    index = close + 1;
  }
  return blocks;
}

(_WalkInline, List<ParsedBlock>) _listItemContent(
  List<BlockToken> tokens,
  int start,
  int end,
  _Cursor cursor,
  MarkdownLimits limits,
  List<SourceParseWarning> warnings, {
  required List<InlineToken> Function(BlockToken token) childrenOf,
  required int quoteDepth,
  required int itemDepth,
}) {
  final walkInline = _WalkInline();
  final nested = <ParsedBlock>[];
  var index = start;
  while (index < end) {
    final token = tokens[index];
    if (token.type == 'paragraph_open' &&
        index + 1 < end &&
        tokens[index + 1].type == 'inline') {
      final part = _walkInline(
        childrenOf(tokens[index + 1]),
        limits,
        cursor.blockIndex + 1,
      );
      if (part.text.trim().isNotEmpty) {
        if (walkInline.text.isNotEmpty) {
          walkInline.text += ' ${part.text}';
          // The paragraph junction is a softbreak in visible text and must
          // exist in the run stream too (same fix as PC).
          walkInline.runs.add(
            const ArticleRun(kind: ArticleRunKind.plain, text: ' '),
          );
          walkInline.runs.addAll(part.runs);
          _mergeAdjacentPlain(walkInline.runs);
        } else {
          walkInline.text = part.text;
          walkInline.runs = [...part.runs];
        }
      }
      index += 3;
    } else if (token.type == 'bullet_list_open' ||
        token.type == 'ordered_list_open' ||
        token.type == 'blockquote_open') {
      final closeType = token.type.replaceFirst('_open', '_close');
      final close = _matchingClose(tokens, index, end, token.type, closeType);
      nested.addAll(
        _parseTokens(
          tokens,
          index,
          close + 1,
          cursor,
          limits,
          warnings,
          childrenOf: childrenOf,
          quoteDepth: quoteDepth,
          listDepth: itemDepth,
        ),
      );
      index = close + 1;
    } else {
      index += 1;
    }
  }
  return (walkInline, nested);
}

ParsedTableBlock _parseTable(
  List<BlockToken> tokens,
  int start,
  int end,
  _Cursor cursor,
  MarkdownLimits limits,
  int blockIndex,
  List<InlineToken> Function(BlockToken token) childrenOf,
) {
  final alignments = <TableAlignment>[];
  final header = <ParsedTableCell>[];
  final rows = <List<ParsedTableCell>>[];
  var totalCharacters = 0;
  var cellIndex = 0;
  var padCounter = 0;
  List<ParsedTableCell>? currentRow;
  var index = start;
  final blockNumber = cursor.blockNumber + 1;
  while (index < end) {
    final token = tokens[index];
    if (token.type == 'th_open' || token.type == 'td_open') {
      final close = _matchingClose(
        tokens,
        index,
        end,
        token.type,
        '${token.type.substring(0, 2)}_close',
      );
      final walkInline = _walkInline(
        childrenOf(tokens[index + 1]),
        limits,
        blockIndex,
      );
      final plain = walkInline.text.trim();
      if (codePointLength(plain) > limits.maxTableCellCharacters) {
        throw const SourceParseException(
          'resource_limit',
          ' (table cell characters)',
        );
      }
      totalCharacters += codePointLength(plain);
      if (token.type == 'td_open' && currentRow == null) {
        currentRow = [];
      }
      final clipped = _clipRuns(
        walkInline.runs,
        _offsetOf(walkInline.text, plain),
        codePointLength(plain),
      );
      // PC TableCell construction replaces empty runs with a single plain run
      // of the cell text (design §5.2.5 invariant).
      final cell = ParsedTableCell(
        cellId: 'cell-$blockNumber-$cellIndex',
        text: plain,
        runs: clipped.isEmpty
            ? [ArticleRun(kind: ArticleRunKind.plain, text: plain)]
            : clipped,
      );
      cellIndex += 1;
      if (token.type == 'th_open') {
        header.add(cell);
        alignments.add(_alignment(token));
      } else if (currentRow != null) {
        currentRow.add(cell);
      }
      index = close + 1;
    } else if (token.type == 'tr_close') {
      if (currentRow != null) {
        rows.add(currentRow);
        currentRow = null;
      }
      index += 1;
    } else {
      index += 1;
    }
  }
  if (currentRow != null) rows.add(currentRow);
  // GFM pads missing cells with empty ones; mirrors PC deterministically.
  for (final row in rows) {
    while (row.length < header.length) {
      row.add(
        ParsedTableCell(
          cellId: 'cell-$blockNumber-pad-$padCounter',
          text: '',
          runs: [const ArticleRun(kind: ArticleRunKind.plain, text: '')],
        ),
      );
      padCounter += 1;
    }
    if (row.length > header.length) {
      row.removeRange(header.length, row.length);
    }
  }
  if (header.isEmpty) {
    throw const SourceParseException('no_blocks', ' (table without header)');
  }
  if (header.length > limits.maxTableColumns) {
    throw const SourceParseException('resource_limit', ' (table columns)');
  }
  if (rows.length > limits.maxTableRows) {
    throw const SourceParseException('resource_limit', ' (table rows)');
  }
  if (totalCharacters > limits.maxTableTotalCharacters) {
    throw const SourceParseException(
      'resource_limit',
      ' (table total characters)',
    );
  }
  if (alignments.length != header.length) {
    final trimmed = alignments.take(header.length).toList();
    alignments
      ..clear()
      ..addAll(
        trimmed.isNotEmpty
            ? trimmed
            : List.filled(header.length, TableAlignment.inherit),
      );
  }
  return ParsedTableBlock(
    blockId: cursor.nextBlockId(),
    order: 0,
    alignments: alignments.take(header.length).toList(),
    header: header,
    rows: rows.map((row) => List<ParsedTableCell>.of(row)).toList(),
    translationById: const {},
  );
}

TableAlignment _alignment(BlockToken token) {
  final style = token.attrs?['style'] ?? '';
  return switch (style) {
    'text-align:left' => TableAlignment.left,
    'text-align:center' => TableAlignment.center,
    'text-align:right' => TableAlignment.right,
    _ => TableAlignment.inherit,
  };
}

int _offsetOf(String fullText, String stripped) {
  final offset = fullText.indexOf(stripped);
  return offset < 0 ? 0 : offset;
}

// ---- inline walk -----------------------------------------------------------

_WalkInline _walkInline(
  List<InlineToken> children,
  MarkdownLimits limits,
  int blockIndex,
) {
  final result = _WalkInline();
  if (children.isEmpty) return result;
  final styles = <String>[];
  String? pendingHref;
  for (final child in children) {
    switch (child.type) {
      case 'text':
        final normalized = normalizeVisibleText(child.content);
        result.text += normalized;
        result.runs.add(
          ArticleRun(
            kind: _currentStyle(styles),
            text: normalized,
            href: pendingHref,
          ),
        );
      case 'code_inline':
        result.text += child.content;
        result.runs.add(
          ArticleRun(kind: ArticleRunKind.code, text: child.content),
        );
      case 'softbreak':
        result.text += ' ';
        result.runs.add(
          ArticleRun(kind: _currentStyle(styles), text: ' ', href: pendingHref),
        );
      case 'hardbreak':
        result.text += '\n';
        result.runs.add(
          const ArticleRun(kind: ArticleRunKind.hardBreak, text: '\n'),
        );
      case 'em_open' || 'strong_open' || 's_open' || 'link_open':
        styles.add(
          {
            'em_open': 'emphasis',
            'strong_open': 'strong',
            's_open': 'strikethrough',
            'link_open': 'link',
          }[child.type]!,
        );
        if (child.type == 'link_open') {
          pendingHref = child.attrs?['href'] ?? '';
          if (pendingHref.length > limits.maxLinkHrefCharacters) {
            throw const SourceParseException(
              'resource_limit',
              ' (link href characters)',
            );
          }
        }
      case 'em_close' || 'strong_close' || 's_close' || 'link_close':
        if (styles.isNotEmpty) styles.removeLast();
        if (child.type == 'link_close') pendingHref = null;
      case 'image':
        var alt = child.content;
        if (alt.isEmpty && child.children != null) {
          alt = [
            for (final nested in child.children!)
              if (nested.type == 'text') nested.content,
          ].join();
        }
        alt = alt.isEmpty ? '' : normalizeVisibleText(alt);
        final text = alt.trim().isNotEmpty ? alt : '[图片未包含]';
        final src = child.attrs?['src'];
        result.text += text;
        result.runs.add(
          ArticleRun(
            kind: ArticleRunKind.image,
            text: text,
            href: (src != null && src.isNotEmpty) ? src : null,
          ),
        );
      case 'html_inline':
        throw SourceParseException('raw_html', ' (block position $blockIndex)');
      default:
        break;
    }
  }
  if (result.runs.length > limits.maxSentenceRuns) {
    throw SourceParseException(
      'resource_limit',
      ' (inline runs, block position $blockIndex)',
    );
  }
  _mergeAdjacentPlain(result.runs);
  return result;
}

ArticleRunKind _currentStyle(List<String> styles) {
  if (styles.isEmpty) return ArticleRunKind.plain;
  var best = ArticleRunKind.plain;
  var bestPriority = 0;
  for (final style in styles) {
    final priority = _stylePriority[style] ?? 0;
    if (priority > bestPriority) {
      bestPriority = priority;
      best = _styleKind(style);
    }
  }
  return best;
}

ArticleRunKind _styleKind(String style) => switch (style) {
  'emphasis' => ArticleRunKind.emphasis,
  'strong' => ArticleRunKind.strong,
  'strikethrough' => ArticleRunKind.strikethrough,
  'link' => ArticleRunKind.link,
  'code' => ArticleRunKind.code,
  'image' => ArticleRunKind.image,
  _ => ArticleRunKind.plain,
};

void _mergeAdjacentPlain(List<ArticleRun> runs) {
  final merged = <ArticleRun>[];
  for (final run in runs) {
    final last = merged.isEmpty ? null : merged.last;
    if (last != null &&
        last.kind == run.kind &&
        last.kind != ArticleRunKind.hardBreak &&
        last.href == run.href) {
      merged[merged.length - 1] = ArticleRun(
        kind: last.kind,
        text: last.text + run.text,
        href: last.href,
      );
    } else {
      merged.add(run);
    }
  }
  runs
    ..clear()
    ..addAll(merged);
}

List<ArticleRun> _clipRuns(List<ArticleRun> runs, int offset, int length) {
  final clipped = <ArticleRun>[];
  var position = 0;
  for (final run in runs) {
    final runEnd = position + run.text.length;
    final start = position > offset ? position : offset;
    final end = runEnd < offset + length ? runEnd : offset + length;
    if (end > start) {
      clipped.add(
        ArticleRun(
          kind: run.kind,
          text: run.text.substring(start - position, end - position),
          href: run.href,
        ),
      );
    }
    position = runEnd;
    if (position >= offset + length) break;
  }
  return clipped;
}

// ---- block builders ----------------------------------------------------------

ParsedTextBlock _textBlock(
  _Cursor cursor, {
  required ArticleTextKind kind,
  required _WalkInline inline,
  required MarkdownLimits limits,
  int? headingLevel,
  ArticleListKind? listKind,
  int listDepth = 0,
  int? listOrdinal,
  int quoteDepth = 0,
}) {
  final spans = sentenceSpans(inline.text);
  final sentences = <SentenceContent>[];
  for (final (start, end) in spans) {
    final text = inline.text.substring(start, end);
    if (text.trim().isEmpty) continue;
    sentences.add(
      SentenceContent(
        sentenceId: cursor.nextSentenceId(),
        order: sentences.length,
        text: text,
        runs: _clipRuns(inline.runs, start, end - start),
      ),
    );
  }
  if (sentences.isEmpty) {
    // PC's TextBlock rejects zero-sentence text blocks (only reachable via
    // headings); mobile reports it as a clean parse error.
    throw const SourceParseException('empty_text_block');
  }
  if (sentences.length > limits.maxBlockSentences) {
    throw const SourceParseException('resource_limit', ' (block sentences)');
  }
  for (final sentence in sentences) {
    if (codePointLength(sentence.text) > limits.maxSentenceCharacters) {
      throw const SourceParseException(
        'resource_limit',
        ' (sentence characters)',
      );
    }
  }
  return ParsedTextBlock(
    blockId: cursor.nextBlockId(),
    order: 0,
    kind: kind,
    sentences: sentences,
    level: headingLevel,
    listKind: listKind,
    listDepth: listDepth,
    listOrdinal: listOrdinal,
    quoteDepth: quoteDepth,
  );
}

ParsedCodeBlock _codeBlock(
  _Cursor cursor,
  String code,
  String? language,
  MarkdownLimits limits,
) {
  if (utf8ByteLength(code) > limits.maxCodeBlockBytes) {
    throw const SourceParseException('resource_limit', ' (code block bytes)');
  }
  if (language != null && language.length > limits.maxLanguageCharacters) {
    throw const SourceParseException('resource_limit', ' (code language)');
  }
  return ParsedCodeBlock(
    blockId: cursor.nextBlockId(),
    order: 0,
    code: code,
    language: language,
  );
}

int utf8ByteLength(String text) {
  var bytes = 0;
  for (final rune in text.runes) {
    if (rune < 0x80) {
      bytes += 1;
    } else if (rune < 0x800) {
      bytes += 2;
    } else if (rune < 0x10000) {
      bytes += 3;
    } else {
      bytes += 4;
    }
  }
  return bytes;
}

ParsedBlock _withOrder(ParsedBlock block, int order) {
  switch (block) {
    case ParsedTextBlock b:
      return ParsedTextBlock(
        blockId: b.blockId,
        order: order,
        kind: b.kind,
        sentences: b.sentences,
        level: b.level,
        listKind: b.listKind,
        listDepth: b.listDepth,
        listOrdinal: b.listOrdinal,
        quoteDepth: b.quoteDepth,
      );
    case ParsedTableBlock b:
      return ParsedTableBlock(
        blockId: b.blockId,
        order: order,
        alignments: b.alignments,
        header: b.header,
        rows: b.rows,
        translationById: b.translationById,
      );
    case ParsedCodeBlock b:
      return ParsedCodeBlock(
        blockId: b.blockId,
        order: order,
        code: b.code,
        language: b.language,
      );
    case ParsedDividerBlock b:
      return ParsedDividerBlock(blockId: b.blockId, order: order);
  }
}
