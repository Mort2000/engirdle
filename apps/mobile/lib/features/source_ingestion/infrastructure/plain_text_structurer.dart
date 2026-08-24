import '../../../../contracts/readpack_v1/article.dart';
import '../domain/source_parse_error.dart';
import 'markdown/markdown_limits.dart';
import 'segmenter.dart';
import 'unicode_text.dart';

/// Structures plain text (design §6.1): blank-line blocks, each a paragraph
/// whose lines join with softbreak spaces, segmented by the shared English
/// sentence rules with plain runs. No markdown interpretation ever happens —
/// `#` stays literal text. PC has no plain-text path, so the parity anchor is
/// the shared segmenter/normalizer (contracts/source/v1 §对齐规则 2/3).
class PlainTextStructurer {
  const PlainTextStructurer({this.limits = defaultMarkdownLimits});

  final MarkdownLimits limits;

  List<ParsedBlock> structure(String canonical) {
    final blocks = <ParsedBlock>[];
    var blockNumber = 0;
    var sentenceNumber = 0;
    final pending = <String>[];

    void flush() {
      if (pending.isEmpty) return;
      final joined = pending.join(' ');
      pending.clear();
      final spans = sentenceSpans(joined);
      final sentences = <SentenceContent>[];
      for (final (start, end) in spans) {
        final text = joined.substring(start, end);
        if (text.trim().isEmpty) continue;
        sentenceNumber += 1;
        sentences.add(
          SentenceContent(
            sentenceId: 'sentence-$sentenceNumber',
            order: sentences.length,
            text: text,
            runs: [ArticleRun(kind: ArticleRunKind.plain, text: text)],
          ),
        );
      }
      if (sentences.isEmpty) {
        // A block of only filterable content: identical to PC's markdown
        // behavior of skipping whitespace-only paragraphs.
        return;
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
      blockNumber += 1;
      blocks.add(
        ParsedTextBlock(
          blockId: 'block-$blockNumber',
          order: blocks.length,
          kind: ArticleTextKind.paragraph,
          sentences: sentences,
        ),
      );
    }

    for (final line in canonical.split('\n')) {
      final normalized = normalizeVisibleText(line);
      if (_isBlank(normalized)) {
        flush();
        continue;
      }
      pending.add(normalized);
    }
    flush();

    if (blocks.isEmpty) {
      throw const SourceParseException('empty_body');
    }
    if (blocks.length > limits.maxBlocks) {
      throw const SourceParseException('resource_limit', ' (document blocks)');
    }
    return blocks;
  }

  static bool _isBlank(String normalizedLine) {
    for (var i = 0; i < normalizedLine.length; i++) {
      if (!isPythonSpace(normalizedLine.codeUnitAt(i))) return false;
    }
    return true;
  }
}
