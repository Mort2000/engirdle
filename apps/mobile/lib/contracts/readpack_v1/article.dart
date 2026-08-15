import 'dart:convert';

import '../contract_violation.dart';

/// Readpack v1 article.json — ordered blocks and sentences (design §3).
///
/// v1.1 (markdown-blocks) turns blocks into a typed discriminated union
/// (text / table / code / divider) and gives every sentence non-empty inline
/// [ArticleRun]s whose texts concatenate to the sentence text. v1.0 keeps the
/// paragraph/list_item/quote-only shape; its sentences carry no runs and are
/// normalized to a single plain run so downstream code sees one model.
class ArticleContent {
  const ArticleContent({
    required this.formatVersion,
    required this.requiredCapabilities,
    required this.articleId,
    required this.revision,
    required this.title,
    required this.source,
    required this.sourceSha256,
    required this.structureSha256,
    required this.blocks,
  });

  final String formatVersion;

  /// Article-side required_capabilities; must equal the manifest's list
  /// (checked by the cross-file validator).
  final List<String> requiredCapabilities;

  final String articleId;
  final int revision;
  final String title;
  final ArticleSource source;
  final String sourceSha256;
  final String structureSha256;
  final List<ParsedBlock> blocks;

  static ArticleContent parse(Object? json) {
    final r = JsonReader(json, 'article');
    r['format'].mustEqual('readpack-article', 'format');
    final formatVersion = r['format_version'].v1Version();
    final isV11 = formatVersion == '1.1';
    final capabilities = _parseCapabilities(r, isV11);

    final source = r['source'];
    final parsedSource = ArticleSource(
      displayName: source['display_name']
          .asStringOrNull(minLength: 1, maxLength: 512),
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
      // The contract pins order to the array position (starting at 0), not
      // merely to a contiguous set: duplicates and shuffles both reject.
      final order = b['order'].order();
      if (order != i) {
        throw ContractViolation('article.blocks[$i].order',
            'order $order does not match position $i');
      }
      // v1.0 only knows paragraph/list_item/quote; on that path the v1.1-only
      // kinds are indistinguishable from unknown kinds (COMPATIBILITY.md: a
      // v1.0 package must not carry v1.1 block kinds). The version gate runs
      // before the cross-kind payload check so the reported reason matches.
      final ParsedBlock parsed;
      switch (kind) {
        case 'paragraph' || 'heading' || 'list_item' || 'quote' when isV11:
          _rejectCrossKindFields(b, i, kind);
          parsed = _parseTextBlock(b, i, kind, sentenceIds, isV11: true);
        case 'paragraph' || 'list_item' || 'quote':
          _rejectCrossKindFields(b, i, kind);
          parsed = _parseTextBlock(b, i, kind, sentenceIds, isV11: false);
        case 'table' when isV11:
          _rejectCrossKindFields(b, i, kind);
          parsed = _parseTableBlock(b, i, cellIds);
        case 'code' when isV11:
          _rejectCrossKindFields(b, i, kind);
          final code = _parseCodeBody(b, i);
          totalCodeBytes += utf8.encode(code).length;
          parsed = _parseCodeBlock(b, i, code);
        case 'divider' when isV11:
          _rejectCrossKindFields(b, i, kind);
          parsed = ParsedDividerBlock(blockId: blockId, order: order);
        case 'heading' || 'table' || 'code' || 'divider':
          throw ContractViolation('article.blocks[$i].kind',
              'unknown block kind "$kind" for v1.0 articles');
        default:
          throw ContractViolation(
              'article.blocks[$i].kind', 'unknown block kind "$kind"');
      }
      blocks.add(parsed);
    }
    // The document-level code budget shares the frozen contract values with
    // the PC freeze and readpack validation (design §4.4).
    if (totalCodeBytes > maxTotalCodeBytes) {
      throw const ContractViolation('article.blocks',
          'total code bytes exceed the 2 MiB document limit');
    }

    return ArticleContent(
      formatVersion: formatVersion,
      requiredCapabilities: capabilities,
      articleId: r['article_id'].uuid(),
      revision: r['revision'].positiveInt(),
      title: r['title'].asString(minLength: 1, maxLength: 512),
      source: parsedSource,
      sourceSha256: r['source_sha256'].sha256(),
      structureSha256: r['structure_sha256'].sha256(),
      blocks: blocks,
    );
  }

  /// Capability tokens share the manifest schema array rules: at most 8
  /// unique tokens matching ^[a-z][a-z0-9-]*$ . Whether a version may
  /// declare them at all is version semantics: 1.1 must require
  /// markdown-blocks, 1.0 none.
  static List<String> _parseCapabilities(JsonReader r, bool isV11) {
    final readers =
        r.optional('required_capabilities')?.asArray(maxItems: 8) ??
            const <JsonReader>[];
    final capabilities = <String>[];
    for (var i = 0; i < readers.length; i++) {
      final capability = readers[i].asString(
        minLength: 1,
        maxLength: 64,
        pattern: RegExp(r'^[a-z][a-z0-9-]*$'),
      );
      if (capabilities.contains(capability)) {
        throw ContractViolation('article.required_capabilities[$i]',
            'duplicate capability "$capability"');
      }
      capabilities.add(capability);
    }
    if (isV11) {
      if (!capabilities.contains('markdown-blocks')) {
        throw const ContractViolation('article.required_capabilities',
            'a 1.1 article must require the markdown-blocks capability');
      }
    } else if (capabilities.isNotEmpty) {
      throw const ContractViolation('article.required_capabilities',
          'a v1.0 article must not declare required_capabilities');
    }
    return capabilities;
  }

  static ParsedTextBlock _parseTextBlock(
    JsonReader b,
    int i,
    String kind,
    Set<String> sentenceIds, {
    required bool isV11,
  }) {
    int? level;
    ArticleListKind? listKind;
    var listDepth = 0;
    int? listOrdinal;
    var quoteDepth = 1;
    switch (kind) {
      case 'heading':
        level = b['level'].asInt(min: 1, max: 6);
      case 'list_item':
        // v1.1 list items carry their kind explicitly; a v1.0 list item has
        // no list payload and decodes to the bullet default (COMPATIBILITY.md).
        if (isV11) {
          final wire = b['list_kind'].asString();
          listKind = switch (wire) {
            'bullet' => ArticleListKind.bullet,
            'ordered' => ArticleListKind.ordered,
            _ => throw ContractViolation('article.blocks[$i].list_kind',
                'list_item blocks need list_kind bullet|ordered'),
          };
          listDepth = b.optional('list_depth')?.asInt(min: 0, max: 4) ?? 0;
          listOrdinal =
              b.optional('list_ordinal')?.asInt(min: 0, max: 2147483647);
        } else {
          listKind = ArticleListKind.bullet;
        }
      case 'quote':
        if (isV11) {
          quoteDepth = b['quote_depth'].asInt(min: 1, max: 4);
        }
      case 'paragraph':
        break;
    }

    final sentenceReaders = b.optional('sentences')?.asArray(
          minItems: 1,
          maxItems: 10000,
        ) ??
        (throw ContractViolation(
            'article.blocks[$i].sentences', 'text blocks need sentences'));
    final sentences = <SentenceContent>[];
    for (var j = 0; j < sentenceReaders.length; j++) {
      final s = sentenceReaders[j];
      final sentenceId = s['sentence_id'].opaqueId();
      if (!sentenceIds.add(sentenceId)) {
        throw ContractViolation(
            'article.blocks[$i].sentences[$j].sentence_id', 'duplicate id');
      }
      sentences.add(_parseSentence(s, i, j, sentenceId, isV11: isV11));
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

  static SentenceContent _parseSentence(
    JsonReader s,
    int blockIndex,
    int sentenceIndex,
    String sentenceId, {
    required bool isV11,
  }) {
    final order = s['order'].order();
    if (order != sentenceIndex) {
      throw ContractViolation(
          'article.blocks[$blockIndex].sentences[$sentenceIndex].order',
          'order $order does not match position $sentenceIndex');
    }
    final text = s['text'].asString(minLength: 1, maxLength: 20000);
    final runReaders = s.optional('runs')?.asArray(maxItems: 2048);
    final List<ArticleRun> runs;
    if (runReaders == null) {
      // v1.1 sentences MUST carry non-empty runs; an absent array stays
      // empty so the semantic validator rejects it. v1.0 sentences have no
      // runs and are normalized to one plain run (COMPATIBILITY.md).
      runs = isV11
          ? const []
          : [ArticleRun(kind: ArticleRunKind.plain, text: text)];
    } else {
      runs = [
        for (final rr in runReaders)
          _parseRun(rr, 'article.blocks[$blockIndex].sentences[$sentenceIndex]')
      ];
    }
    return SentenceContent(
      sentenceId: sentenceId,
      order: order,
      text: text,
      runs: runs,
      translationZh: s.optional('translation_zh')?.asStringOrNull(
            minLength: 1,
            maxLength: 40000,
          ),
      audioStartSample: s.optional('audio_start_sample')?.samplePosition(),
      audioEndSample: s.optional('audio_end_sample')?.samplePosition(),
      audioStartMs: s.optional('audio_start_ms')?.millisecondPosition(),
      audioEndMs: s.optional('audio_end_ms')?.millisecondPosition(),
    );
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

  static ParsedTableBlock _parseTableBlock(
      JsonReader b, int i, Set<String> cellIds) {
    if (b.optional('sentences') != null) {
      throw ContractViolation('article.blocks[$i].sentences',
          'table blocks must not carry sentences');
    }
    final alignmentReaders =
        b.optional('alignments')?.asArray(minItems: 1, maxItems: 32) ??
            (throw ContractViolation('article.blocks[$i].alignments',
                'table blocks need alignments'));
    final alignments = <TableAlignment>[];
    for (final ar in alignmentReaders) {
      final alignment = TableAlignmentWire.fromWire(ar.asString());
      if (alignment == null) {
        throw ContractViolation('article.blocks[$i].alignments',
            'unknown column alignment "${ar.value}"');
      }
      alignments.add(alignment);
    }
    final headerReaders =
        b.optional('header')?.asArray(minItems: 1, maxItems: 32) ??
            (throw ContractViolation(
                'article.blocks[$i].header', 'table blocks need a header row'));
    final header = [
      for (final c in headerReaders) _parseTableCell(c, i, cellIds),
    ];
    if (alignments.length != header.length) {
      throw ContractViolation('article.blocks[$i].alignments',
          'table alignment count must match the header width');
    }
    // `rows` is REQUIRED by the wire schema — a header-only table carries an
    // explicit empty array, and a missing key is a contract violation rather
    // than "no rows".
    final rowReaders = b['rows'].asArray(maxItems: 256);
    final rows = <List<ParsedTableCell>>[];
    for (var r = 0; r < rowReaders.length; r++) {
      final cells = rowReaders[r].asArray(minItems: 1, maxItems: 32);
      if (cells.length != header.length) {
        throw ContractViolation('article.blocks[$i].rows[$r]',
            'table rows must match the header width');
      }
      rows.add([for (final c in cells) _parseTableCell(c, i, cellIds)]);
    }
    final translationReader = b.optional('translation_zh');
    final translation = <String, String>{};
    if (translationReader != null) {
      for (final entry in translationReader.asObject().entries) {
        if (entry.value == null) continue;
        translation[entry.key] = JsonReader(
                entry.value, '${translationReader.path}.${entry.key}')
            .asString(minLength: 1, maxLength: 40000);
      }
    }
    if (translation.isEmpty) {
      throw ContractViolation('article.blocks[$i].translation_zh',
          'table blocks need a cell-id translation map');
    }
    // Frozen table text budget, shared with the PC validation (§4.4).
    // Counted in Unicode codepoints like the JSON Schema semantics — UTF-16
    // units would double-count non-BMP characters.
    final totalCharacters = [
      for (final cell in [...header, ...rows.expand((row) => row)])
        cell.text.runes.length,
    ].fold<int>(0, (sum, length) => sum + length);
    if (totalCharacters > maxTableTotalCharacters) {
      throw ContractViolation('article.blocks[$i]',
          'table visible text exceeds $maxTableTotalCharacters characters');
    }
    return ParsedTableBlock(
      blockId: b['block_id'].opaqueId(),
      order: b['order'].order(),
      alignments: alignments,
      header: header,
      rows: rows,
      translationById: translation,
    );
  }

  static ParsedTableCell _parseTableCell(
      JsonReader c, int i, Set<String> cellIds) {
    final cellId = c['cell_id'].opaqueId();
    if (!cellIds.add(cellId)) {
      throw ContractViolation(
          'article.blocks[$i].cell_id', 'duplicate table cell id "$cellId"');
    }
    final text = c['text'].asString(maxLength: 4000);
    final runReaders = c.optional('runs')?.asArray(maxItems: 2048);
    final runs = runReaders == null
        ? const <ArticleRun>[]
        : [
            for (final rr in runReaders)
              _parseRun(rr, 'article.blocks[$i].cells($cellId)')
          ];
    if (runReaders != null && runs.map((run) => run.text).join() != text) {
      throw ContractViolation('article.blocks[$i].runs',
          'cell runs must concatenate to the cell text');
    }
    return ParsedTableCell(cellId: cellId, text: text, runs: runs);
  }

  /// Known block-level payload fields grouped by the kind that may carry
  /// them (design §5.1): a block carrying another kind's payload rejects.
  /// Unknown fields stay allowed so later 1.x minors can extend the union.
  static const _kindFields = <String, Set<String>>{
    'paragraph': {'block_id', 'kind', 'order', 'sentences'},
    'list_item': {
      'block_id',
      'kind',
      'order',
      'sentences',
      'list_kind',
      'list_depth',
      'list_ordinal'
    },
    'quote': {'block_id', 'kind', 'order', 'sentences', 'quote_depth'},
    'heading': {'block_id', 'kind', 'order', 'sentences', 'level'},
    'table': {
      'block_id',
      'kind',
      'order',
      'alignments',
      'header',
      'rows',
      'translation_zh'
    },
    'code': {'block_id', 'kind', 'order', 'code', 'language'},
    'divider': {'block_id', 'kind', 'order'},
  };
  static const _allKindFields = {
    'sentences',
    'level',
    'list_kind',
    'list_depth',
    'list_ordinal',
    'quote_depth',
    'alignments',
    'header',
    'rows',
    'translation_zh',
    'code',
    'language',
  };

  static void _rejectCrossKindFields(JsonReader b, int i, String kind) {
    final legal = _kindFields[kind];
    if (legal == null) return;
    for (final field in _allKindFields.difference(legal)) {
      if (b.optional(field) != null) {
        throw ContractViolation('article.blocks[$i].$field',
            '"$kind" blocks must not carry the "$field" payload');
      }
    }
  }

  /// The frozen per-block code limit is UTF-8 bytes, shared with the PC
  /// freeze/readpack validation (design §4.4). The codepoint bound is the
  /// necessary schema-side condition; the byte check is exact.
  static const maxCodeBlockBytes = 512 * 1024;
  static const maxTotalCodeBytes = 2 * 1024 * 1024;
  static const maxTableTotalCharacters = 200000;

  static String _parseCodeBody(JsonReader b, int i) {
    final code = b.optional('code')?.asString(minLength: 1, maxLength: 524288);
    if (code == null) {
      throw ContractViolation(
          'article.blocks[$i].code', 'code blocks need a non-empty body');
    }
    if (utf8.encode(code).length > maxCodeBlockBytes) {
      throw ContractViolation('article.blocks[$i].code',
          'code blocks must not exceed $maxCodeBlockBytes bytes');
    }
    return code;
  }

  static ParsedCodeBlock _parseCodeBlock(JsonReader b, int i, String code) {
    if (b.optional('translation_zh') != null) {
      throw ContractViolation('article.blocks[$i].translation_zh',
          'code blocks must not carry translations');
    }
    if (b.optional('sentences') != null) {
      throw ContractViolation('article.blocks[$i].sentences',
          'code blocks must not carry sentences');
    }
    return ParsedCodeBlock(
      blockId: b['block_id'].opaqueId(),
      order: b['order'].order(),
      language:
          b.optional('language')?.asStringOrNull(minLength: 1, maxLength: 64),
      code: code,
    );
  }

  /// All sentences in reading order (text blocks sorted by order, then
  /// sentences). Table/code/divider blocks are never narratable and never
  /// appear here, so playback ranges can only ever cover sentences.
  List<SentenceContent> get sentencesInOrder => [
        for (final block in [...blocks]..sort((a, b) => a.order - b.order))
          if (block is ParsedTextBlock)
            ...([...block.sentences]..sort((a, b) => a.order - b.order)),
      ];
}

class ArticleSource {
  const ArticleSource({this.displayName, this.url, this.author});

  final String? displayName;
  final String? url;
  final String? author;
}

/// The four narratable (sentence-bearing) text block kinds.
enum ArticleTextKind {
  paragraph,
  heading,
  listItem,
  quote;

  static ArticleTextKind fromWire(String wire) => switch (wire) {
        'paragraph' => paragraph,
        'heading' => heading,
        'list_item' => listItem,
        'quote' => quote,
        _ => throw ContractViolation('kind', 'unknown text kind "$wire"'),
      };

  String get wire => switch (this) {
        paragraph => 'paragraph',
        heading => 'heading',
        listItem => 'list_item',
        quote => 'quote',
      };
}

enum ArticleListKind { bullet, ordered }

/// v1.1 table alignments. The wire value "default" lets the renderer
/// inherit, so the enum member is named [inherit].
enum TableAlignment { inherit, left, center, right }

extension TableAlignmentWire on TableAlignment {
  static TableAlignment? fromWire(String wire) => switch (wire) {
        'default' => TableAlignment.inherit,
        'left' => TableAlignment.left,
        'center' => TableAlignment.center,
        'right' => TableAlignment.right,
        _ => null,
      };

  String get wire => switch (this) {
        TableAlignment.inherit => 'default',
        TableAlignment.left => 'left',
        TableAlignment.center => 'center',
        TableAlignment.right => 'right',
      };
}

/// Inline styling run kind. Run texts concatenate to exactly the owning
/// sentence (or cell) text; consumers render styles and never resegment.
enum ArticleRunKind {
  plain,
  emphasis,
  strong,
  strikethrough,
  code,
  link,
  image,
  hardBreak;

  static ArticleRunKind? fromWire(String wire) => switch (wire) {
        'plain' => plain,
        'emphasis' => emphasis,
        'strong' => strong,
        'strikethrough' => strikethrough,
        'code' => code,
        'link' => link,
        'image' => image,
        'hard_break' => hardBreak,
        _ => null,
      };

  String get wire => switch (this) {
        plain => 'plain',
        emphasis => 'emphasis',
        strong => 'strong',
        strikethrough => 'strikethrough',
        code => 'code',
        link => 'link',
        image => 'image',
        hardBreak => 'hard_break',
      };
}

class ArticleRun {
  const ArticleRun({required this.kind, required this.text, this.href});

  final ArticleRunKind kind;

  /// The literal text slice; empty only for hard breaks.
  final String text;

  /// Link target (link runs). Only http/https targets are ever actionable in
  /// presentation; other schemes render as plain styled text.
  final String? href;
}

/// The v1.1 block union, discriminated by concrete type.
sealed class ParsedBlock {
  const ParsedBlock({required this.blockId, required this.order});

  final String blockId;
  final int order;
}

/// paragraph / heading / list_item / quote — the sentence-bearing kinds.
class ParsedTextBlock extends ParsedBlock {
  const ParsedTextBlock({
    required super.blockId,
    required super.order,
    required this.kind,
    required this.sentences,
    this.level,
    this.listKind,
    this.listDepth = 0,
    this.listOrdinal,
    this.quoteDepth = 1,
  });

  final ArticleTextKind kind;

  /// heading only: 1-6.
  final int? level;

  /// list_item only.
  final ArticleListKind? listKind;
  final int listDepth;
  final int? listOrdinal;

  /// quote only: 1-4.
  final int quoteDepth;

  final List<SentenceContent> sentences;
}

class ParsedTableBlock extends ParsedBlock {
  const ParsedTableBlock({
    required super.blockId,
    required super.order,
    required this.alignments,
    required this.header,
    required this.rows,
    required this.translationById,
  });

  final List<TableAlignment> alignments;
  final List<ParsedTableCell> header;
  final List<List<ParsedTableCell>> rows;

  /// cell_id to translated text; the key set equals the header+rows cell id
  /// set (validated cross-file).
  final Map<String, String> translationById;
}

class ParsedTableCell {
  const ParsedTableCell({
    required this.cellId,
    required this.text,
    this.runs = const [],
  });

  final String cellId;
  final String text;
  final List<ArticleRun> runs;
}

class ParsedCodeBlock extends ParsedBlock {
  const ParsedCodeBlock({
    required super.blockId,
    required super.order,
    this.language,
    required this.code,
  });

  final String? language;
  final String code;
}

class ParsedDividerBlock extends ParsedBlock {
  const ParsedDividerBlock({required super.blockId, required super.order});
}

class SentenceContent {
  const SentenceContent({
    required this.sentenceId,
    required this.order,
    required this.text,
    required this.runs,
    this.translationZh,
    this.audioStartSample,
    this.audioEndSample,
    this.audioStartMs,
    this.audioEndMs,
  });

  final String sentenceId;
  final int order;
  final String text;

  /// Inline runs; concatenated run texts equal [text]. v1.0 sentences are
  /// normalized to a single plain run at parse time; a v1.1 sentence without
  /// non-empty runs keeps an empty list so the validator rejects it.
  final List<ArticleRun> runs;

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
