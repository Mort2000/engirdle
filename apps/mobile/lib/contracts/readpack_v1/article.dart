import '../contract_violation.dart';

/// Readpack v1 `article.json` — ordered blocks and sentences (design §3).
class ArticleContent {
  const ArticleContent({
    required this.formatVersion,
    required this.articleId,
    required this.revision,
    required this.title,
    required this.source,
    required this.sourceSha256,
    required this.structureSha256,
    required this.blocks,
  });

  final String formatVersion;
  final String articleId;
  final int revision;
  final String title;
  final ArticleSource source;
  final String sourceSha256;
  final String structureSha256;
  final List<ArticleBlock> blocks;

  static ArticleContent parse(Object? json) {
    final r = JsonReader(json, 'article');
    r['format'].mustEqual('readpack-article', 'format');
    final formatVersion = r['format_version'].v1Version();

    final source = r['source'];
    final parsedSource = ArticleSource(
      displayName: source['display_name']
          .asStringOrNull(minLength: 1, maxLength: 512),
      url: source['url'].uriOrNull(),
      author: source['author'].asStringOrNull(minLength: 1, maxLength: 512),
    );

    final blockReaders = r['blocks'].asArray(minItems: 1, maxItems: 10000);
    final blocks = <ArticleBlock>[];
    final blockIds = <String>{};
    final sentenceIds = <String>{};
    for (var i = 0; i < blockReaders.length; i++) {
      final b = blockReaders[i];
      final blockId = b['block_id'].opaqueId();
      if (!blockIds.add(blockId)) {
        throw ContractViolation('article.blocks[$i].block_id', 'duplicate id');
      }
      final kind = b['kind'].asString();
      if (kind != 'paragraph' && kind != 'list_item' && kind != 'quote') {
        throw ContractViolation(
            'article.blocks[$i].kind', 'unknown block kind "$kind"');
      }
      // The contract pins order to the array position (starting at 0), not
      // merely to a contiguous set: duplicates and shuffles both reject.
      final order = b['order'].order();
      if (order != i) {
        throw ContractViolation('article.blocks[$i].order',
            'order $order does not match position $i');
      }
      final sentenceReaders =
          b['sentences'].asArray(minItems: 1, maxItems: 10000);
      final sentences = <SentenceContent>[];
      for (var j = 0; j < sentenceReaders.length; j++) {
        final s = sentenceReaders[j];
        final sentenceId = s['sentence_id'].opaqueId();
        if (!sentenceIds.add(sentenceId)) {
          throw ContractViolation(
              'article.blocks[$i].sentences[$j].sentence_id', 'duplicate id');
        }
        final sentenceOrder = s['order'].order();
        if (sentenceOrder != j) {
          throw ContractViolation('article.blocks[$i].sentences[$j].order',
              'order $sentenceOrder does not match position $j');
        }
        sentences.add(SentenceContent(
          sentenceId: sentenceId,
          order: sentenceOrder,
          text: s['text'].asString(minLength: 1, maxLength: 20000),
          translationZh: s.optional('translation_zh')?.asStringOrNull(
              minLength: 1, maxLength: 40000),
          audioStartSample:
              s.optional('audio_start_sample')?.samplePosition(),
          audioEndSample: s.optional('audio_end_sample')?.samplePosition(),
          audioStartMs: s.optional('audio_start_ms')?.millisecondPosition(),
          audioEndMs: s.optional('audio_end_ms')?.millisecondPosition(),
        ));
      }
      blocks.add(ArticleBlock(
        blockId: blockId,
        kind: kind,
        order: order,
        sentences: sentences,
      ));
    }

    return ArticleContent(
      formatVersion: formatVersion,
      articleId: r['article_id'].uuid(),
      revision: r['revision'].positiveInt(),
      title: r['title'].asString(minLength: 1, maxLength: 512),
      source: parsedSource,
      sourceSha256: r['source_sha256'].sha256(),
      structureSha256: r['structure_sha256'].sha256(),
      blocks: blocks,
    );
  }

  /// All sentences in reading order (blocks sorted by order, then sentences).
  List<SentenceContent> get sentencesInOrder => [
        for (final block in [...blocks]..sort((a, b) => a.order - b.order))
          ...([...block.sentences]..sort((a, b) => a.order - b.order)),
      ];
}

class ArticleSource {
  const ArticleSource({this.displayName, this.url, this.author});

  final String? displayName;
  final String? url;
  final String? author;
}

class ArticleBlock {
  const ArticleBlock({
    required this.blockId,
    required this.kind,
    required this.order,
    required this.sentences,
  });

  final String blockId;
  final String kind;
  final int order;
  final List<SentenceContent> sentences;
}

class SentenceContent {
  const SentenceContent({
    required this.sentenceId,
    required this.order,
    required this.text,
    this.translationZh,
    this.audioStartSample,
    this.audioEndSample,
    this.audioStartMs,
    this.audioEndMs,
  });

  final String sentenceId;
  final int order;
  final String text;
  final String? translationZh;
  final int? audioStartSample;
  final int? audioEndSample;
  final int? audioStartMs;
  final int? audioEndMs;

  bool get hasAudio =>
      audioStartMs != null &&
      audioEndMs != null &&
      audioStartSample != null &&
      audioEndSample != null;
}
