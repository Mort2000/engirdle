import 'dart:convert';

import '../contract_violation.dart';
import '../readpack_v1/article.dart';
import 'version_v2.dart';

/// Readpack v2 `article.json` — the pure source base. Same typed block
/// union as v1.1, minus every derivative field: no translation_zh, no audio
/// sample/millisecond positions (the schema's `not` clauses become explicit
/// rejections here).
class ArticleV2 {
  const ArticleV2({
    required this.articleId,
    required this.revision,
    required this.title,
    required this.source,
    required this.sourceSha256,
    required this.normalizedSha256,
    required this.structureSha256,
    required this.blocks,
  });

  final String articleId;
  final int revision;
  final String title;
  final ArticleSource source;
  final String sourceSha256;
  final String normalizedSha256;
  final String structureSha256;
  final List<ParsedBlock> blocks;

  static ArticleV2 parse(Object? json) {
    final r = JsonReader(json, 'article');
    r['format'].mustEqual('readpack-article', 'format');
    ReadpackV2Version.parse(r['format_version']);

    final source = r['source'];
    final parsedSource = ArticleSource(
      displayName: source['display_name'].asStringOrNull(
        minLength: 1,
        maxLength: 512,
      ),
      url: source['url'].uriOrNull(),
      author: source['author'].asStringOrNull(minLength: 1, maxLength: 512),
    );

    final blockReaders = r['blocks'].asArray(minItems: 1, maxItems: 10000);
    final blocks = <ParsedBlock>[];
    final blockIds = <String>{};
    final sentenceIds = <String>{};
    final cellIds = <String>{};
    var totalCodeBytes = 0;
    for (var i = 0; i < blockReaders.length; i++) {
      final b = blockReaders[i];
      final blockId = b['block_id'].opaqueId();
      if (!blockIds.add(blockId)) {
        throw ContractViolation('article.blocks[$i].block_id', 'duplicate id');
      }
      final kind = b['kind'].asString();
      final order = b['order'].order();
      if (order != i) {
        throw ContractViolation(
          'article.blocks[$i].order',
          'order $order does not match position $i',
        );
      }
      final ParsedBlock parsed;
      switch (kind) {
        case 'paragraph' || 'heading' || 'list_item' || 'quote':
          _rejectDerivativeFields(b, i);
          parsed = _parseTextBlock(b, i, kind, sentenceIds);
        case 'table':
          _rejectDerivativeFields(b, i);
          parsed = _parseTableBlock(b, i, cellIds);
        case 'code':
          _rejectDerivativeFields(b, i);
          final code = b['code'].asString(minLength: 1, maxLength: 524288);
          if (utf8.encode(code).length > ArticleContent.maxCodeBlockBytes) {
            throw ContractViolation(
              'article.blocks[$i].code',
              'code blocks must not exceed ${ArticleContent.maxCodeBlockBytes} bytes',
            );
          }
          totalCodeBytes += utf8.encode(code).length;
          parsed = ParsedCodeBlock(
            blockId: blockId,
            order: order,
            language: b
                .optional('language')
                ?.asStringOrNull(minLength: 1, maxLength: 64),
            code: code,
          );
        case 'divider':
          _rejectDerivativeFields(b, i);
          parsed = ParsedDividerBlock(blockId: blockId, order: order);
        default:
          throw ContractViolation(
            'article.blocks[$i].kind',
            'unknown block kind "$kind"',
          );
      }
      blocks.add(parsed);
    }
    if (totalCodeBytes > ArticleContent.maxTotalCodeBytes) {
      throw const ContractViolation(
        'article.blocks',
        'total code bytes exceed the 2 MiB document limit',
      );
    }

    return ArticleV2(
      articleId: r['article_id'].uuid(),
      revision: r['revision'].positiveInt(),
      title: r['title'].asString(minLength: 1, maxLength: 512),
      source: parsedSource,
      sourceSha256: r['source_sha256'].sha256(),
      normalizedSha256: r['normalized_sha256'].sha256(),
      structureSha256: r['structure_sha256'].sha256(),
      blocks: blocks,
    );
  }

  static const _derivativeFields = [
    'translation_zh',
    'audio_start_sample',
    'audio_end_sample',
    'audio_start_ms',
    'audio_end_ms',
  ];

  static void _rejectDerivativeFields(JsonReader b, int i) {
    for (final field in _derivativeFields) {
      if (b.optional(field) != null) {
        throw ContractViolation(
          'article.blocks[$i].$field',
          'the v2 base never carries derivative fields',
        );
      }
    }
  }

  static ParsedTextBlock _parseTextBlock(
    JsonReader b,
    int i,
    String kind,
    Set<String> sentenceIds,
  ) {
    int? level;
    ArticleListKind? listKind;
    var listDepth = 0;
    int? listOrdinal;
    var quoteDepth = 1;
    switch (kind) {
      case 'heading':
        level = b['level'].asInt(min: 1, max: 6);
      case 'list_item':
        listKind = switch (b['list_kind'].asString()) {
          'bullet' => ArticleListKind.bullet,
          'ordered' => ArticleListKind.ordered,
          _ => throw ContractViolation(
            'article.blocks[$i].list_kind',
            'list_item blocks need list_kind bullet|ordered',
          ),
        };
        listDepth = b.optional('list_depth')?.asInt(min: 0, max: 4) ?? 0;
        listOrdinal = b
            .optional('list_ordinal')
            ?.asInt(min: 0, max: 2147483647);
      case 'quote':
        quoteDepth = b['quote_depth'].asInt(min: 1, max: 4);
      case 'paragraph':
        break;
    }

    final sentenceReaders =
        b.optional('sentences')?.asArray(minItems: 1, maxItems: 10000) ??
        (throw ContractViolation(
          'article.blocks[$i].sentences',
          'text blocks need sentences',
        ));
    final sentences = <SentenceContent>[];
    for (var j = 0; j < sentenceReaders.length; j++) {
      final s = sentenceReaders[j];
      final sentenceId = s['sentence_id'].opaqueId();
      if (!sentenceIds.add(sentenceId)) {
        throw ContractViolation(
          'article.blocks[$i].sentences[$j].sentence_id',
          'duplicate id',
        );
      }
      final order = s['order'].order();
      if (order != j) {
        throw ContractViolation(
          'article.blocks[$i].sentences[$j].order',
          'order $order does not match position $j',
        );
      }
      final text = s['text'].asString(minLength: 1, maxLength: 20000);
      final runs = [
        for (final rr in s['runs'].asArray(minItems: 1, maxItems: 2048))
          _parseRun(rr, 'article.blocks[$i].sentences[$j]'),
      ];
      if (runs.map((run) => run.text).join() != text) {
        throw ContractViolation(
          'article.blocks[$i].sentences[$j].runs',
          'sentence runs must concatenate to the sentence text',
        );
      }
      sentences.add(
        SentenceContent(
          sentenceId: sentenceId,
          order: order,
          text: text,
          runs: runs,
        ),
      );
    }
    return ParsedTextBlock(
      blockId: b['block_id'].opaqueId(),
      order: b['order'].order(),
      kind: ArticleTextKind.fromWire(kind),
      level: level,
      listKind: listKind,
      listDepth: listDepth,
      listOrdinal: listOrdinal,
      quoteDepth: quoteDepth,
      sentences: sentences,
    );
  }

  static ParsedTableBlock _parseTableBlock(
    JsonReader b,
    int i,
    Set<String> cellIds,
  ) {
    if (b.optional('sentences') != null) {
      throw const ContractViolation(
        'article.blocks.sentences',
        'table blocks must not carry sentences',
      );
    }
    final alignments = [
      for (final ar in b['alignments'].asArray(minItems: 1, maxItems: 32))
        TableAlignmentWire.fromWire(ar.asString()) ??
            (throw ContractViolation(
              'article.blocks[$i].alignments',
              'unknown column alignment',
            )),
    ];
    final header = [
      for (final c in b['header'].asArray(minItems: 1, maxItems: 32))
        _parseCell(c, i, cellIds),
    ];
    if (alignments.length != header.length) {
      throw const ContractViolation(
        'article.blocks.alignments',
        'table alignment count must match the header width',
      );
    }
    final rows = [
      for (final rowReader in b['rows'].asArray(maxItems: 256))
        [
          for (final c in rowReader.asArray(minItems: 1, maxItems: 32))
            _parseCell(c, i, cellIds),
        ],
    ];
    for (var r = 0; r < rows.length; r++) {
      if (rows[r].length != header.length) {
        throw ContractViolation(
          'article.blocks[$i].rows[$r]',
          'table rows must match the header width',
        );
      }
    }
    final totalCharacters = [
      for (final cell in [...header, ...rows.expand((row) => row)])
        cell.text.runes.length,
    ].fold<int>(0, (sum, length) => sum + length);
    if (totalCharacters > ArticleContent.maxTableTotalCharacters) {
      throw ContractViolation(
        'article.blocks[$i]',
        'table visible text exceeds ${ArticleContent.maxTableTotalCharacters} characters',
      );
    }
    return ParsedTableBlock(
      blockId: b['block_id'].opaqueId(),
      order: b['order'].order(),
      alignments: alignments,
      header: header,
      rows: rows,
      translationById: const {},
    );
  }

  static ParsedTableCell _parseCell(JsonReader c, int i, Set<String> cellIds) {
    final cellId = c['cell_id'].opaqueId();
    if (!cellIds.add(cellId)) {
      throw ContractViolation(
        'article.blocks[$i].cell_id',
        'duplicate table cell id "$cellId"',
      );
    }
    final text = c['text'].asString(maxLength: 4000);
    final runReaders = c.optional('runs')?.asArray(maxItems: 2048);
    final runs = runReaders == null
        ? [ArticleRun(kind: ArticleRunKind.plain, text: text)]
        : [
            for (final rr in runReaders)
              _parseRun(rr, 'article.blocks[$i].cells($cellId)'),
          ];
    if (runReaders != null && runs.map((run) => run.text).join() != text) {
      throw ContractViolation(
        'article.blocks[$i].runs',
        'cell runs must concatenate to the cell text',
      );
    }
    return ParsedTableCell(cellId: cellId, text: text, runs: runs);
  }

  static ArticleRun _parseRun(JsonReader rr, String path) {
    final wire = rr['kind'].asString();
    final kind = ArticleRunKind.fromWire(wire);
    if (kind == null) {
      throw ContractViolation('$path.runs.kind', 'unknown run kind "$wire"');
    }
    return ArticleRun(
      kind: kind,
      text: rr['text'].asString(maxLength: 20000),
      href: rr.optional('href')?.asStringOrNull(maxLength: 2048),
    );
  }

  /// Text-block sentences in reading order — the coverage set derivatives
  /// must match exactly.
  List<(String blockId, String sentenceId)> get sentenceCoverage => [
    for (final block in blocks)
      if (block is ParsedTextBlock)
        for (final sentence in block.sentences)
          (block.blockId, sentence.sentenceId),
  ];

  /// Table cells per block in header→rows order — the derivative coverage
  /// shape (v2 README: 二维 cell 顺序).
  Map<String, List<String>> get cellCoverageByBlock {
    final coverage = <String, List<String>>{};
    for (final block in blocks) {
      if (block is! ParsedTableBlock) continue;
      coverage[block.blockId] = [
        for (final cell in [
          ...block.header,
          ...block.rows.expand((row) => row),
        ])
          cell.cellId,
      ];
    }
    return coverage;
  }
}
