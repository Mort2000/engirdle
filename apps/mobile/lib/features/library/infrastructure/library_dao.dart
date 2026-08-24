import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../../contracts/contract_violation.dart';
import '../../../contracts/readpack_v1/article.dart';
import '../../../contracts/readpack_v1/manifest.dart';
import '../../../shared_kernel/id_generator.dart';
import '../domain/installed_article.dart';

/// DAO for library-owned tables: the immutable article base (articles,
/// article_artifacts, blocks, sentences), reading modes, and the derivative
/// pointers (article_active_translations, narration_assets). Translation
/// rows are written by installs and the translation module, but reads
/// compose them back here so the reader sees one projection.
///
/// The v1.1 block payload (heading/list/quote styling, table cells, code
/// bodies) and the sentence render runs live in JSON columns — JSON exists
/// only at this seam. Shapes:
///
///   blocks.payload_json:
///     text:    {"level":2} / {"list_kind":"bullet","list_depth":1,
///              "list_ordinal":3} / {"quote_depth":2} / {}
///     table:   {"alignments":["default"],"header":[cell],"rows":[[cell]]}
///     code:    {"language":"python","code":"..."}
///     divider: {}
///   sentences.render_json: [{"kind":"plain","text":"...","href":"..."}]
///
/// Table translations never live in the payload (v5): they are rows in
/// table_cell_translations keyed by the active translation set. The empty
/// payload string (the v4 column default for legacy rows) decodes as a
/// plain paragraph and a single plain run.
class LibraryDao {
  const LibraryDao(this._db);

  final Database _db;

  static const _articleSelect =
      'SELECT a.article_id, a.title, a.author, a.source_display_name, '
      'a.source_url, a.revision, a.current_artifact_revision, a.origin, '
      'a.structure_sha256, a.installed_at, ar.package_id, ar.format_version, '
      'n.audio_path, n.codec, n.sample_rate_hz, n.channels, n.duration_ms '
      'FROM articles a '
      'JOIN article_artifacts ar ON ar.article_id = a.article_id '
      'AND ar.artifact_revision = a.current_artifact_revision '
      'LEFT JOIN narration_assets n ON n.article_id = a.article_id '
      'AND n.artifact_revision = a.current_artifact_revision ';

  List<InstalledArticle> listArticles() {
    final rows = _db.select('$_articleSelect ORDER BY a.title COLLATE NOCASE');
    return [for (final row in rows) _articleFromRow(row)];
  }

  InstalledArticle? getArticle(String articleId) {
    final rows = _db.select('$_articleSelect WHERE a.article_id = ?', [
      articleId,
    ]);
    if (rows.isEmpty) return null;
    return _articleFromRow(rows.first);
  }

  /// Raw stored JSON for the attribution page; null when not installed.
  ({String manifestJson, String attributionJson})? getRawJson(
    String articleId,
  ) {
    final rows = _db.select(
      'SELECT ar.manifest_json, ar.attribution_json '
      'FROM article_artifacts ar JOIN articles a ON a.article_id = '
      'ar.article_id AND a.current_artifact_revision = ar.artifact_revision '
      'WHERE ar.article_id = ?',
      [articleId],
    );
    if (rows.isEmpty) return null;
    return (
      manifestJson: rows.first['manifest_json'] as String,
      attributionJson: rows.first['attribution_json'] as String,
    );
  }

  /// True when an active complete translation set covers the article.
  bool hasActiveTranslation(String articleId) =>
      activeTranslationSetId(articleId) != null;

  /// The active complete set id, or null. Only complete sets may be active;
  /// a drifted pointer (none should exist) reads as no translation.
  String? activeTranslationSetId(String articleId) {
    final rows = _db.select(
      'SELECT ts.translation_set_id FROM article_active_translations aat '
      'JOIN translation_sets ts ON ts.translation_set_id = '
      'aat.translation_set_id '
      "WHERE aat.article_id = ? AND ts.status = 'complete'",
      [articleId],
    );
    if (rows.isEmpty) return null;
    return rows.first['translation_set_id'] as String;
  }

  List<InstalledBlock> getBlocks(String articleId) {
    final blockRows = _db.select(
      'SELECT block_id, kind, ord, payload_json FROM blocks '
      'WHERE article_id = ? ORDER BY ord',
      [articleId],
    );
    final sentenceRows = _db.select(
      'SELECT block_id, sentence_id, ord, text, render_json FROM sentences '
      'WHERE article_id = ? ORDER BY ord',
      [articleId],
    );
    final translationSetId = activeTranslationSetId(articleId);
    final sentenceTranslations = translationSetId == null
        ? const <String, String>{}
        : {
            for (final row in _db.select(
              'SELECT sentence_id, text FROM sentence_translations '
              'WHERE translation_set_id = ?',
              [translationSetId],
            ))
              row['sentence_id'] as String: row['text'] as String,
          };
    final cellTranslations = translationSetId == null
        ? const <String, Map<String, String>>{}
        : _cellTranslations(translationSetId);
    final ranges = _narrationRanges(articleId);
    final byBlock = <String, List<InstalledSentence>>{};
    for (final row in sentenceRows) {
      final sentenceId = row['sentence_id'] as String;
      final text = row['text'] as String;
      final range = ranges[sentenceId];
      byBlock
          .putIfAbsent(row['block_id'] as String, () => [])
          .add(
            InstalledSentence(
              sentenceId: sentenceId,
              blockId: row['block_id'] as String,
              order: row['ord'] as int,
              text: text,
              runs: decodeRuns(
                row['render_json'] as String,
                fallbackText: text,
              ),
              translationZh: sentenceTranslations[sentenceId],
              audioStartMs: range?.startMs,
              audioEndMs: range?.endMs,
            ),
          );
    }
    return [
      for (final row in blockRows)
        _decodeBlock(
          blockId: row['block_id'] as String,
          kind: row['kind'] as String,
          order: row['ord'] as int,
          payloadJson: row['payload_json'] as String,
          sentences: byBlock[row['block_id'] as String] ?? const [],
          cellTranslations: cellTranslations,
        ),
    ];
  }

  Map<String, Map<String, String>> _cellTranslations(String translationSetId) {
    final byBlock = <String, Map<String, String>>{};
    for (final row in _db.select(
      'SELECT block_id, cell_id, text FROM table_cell_translations '
      'WHERE translation_set_id = ?',
      [translationSetId],
    )) {
      byBlock.putIfAbsent(
        row['block_id'] as String,
        () => {},
      )[row['cell_id'] as String] = row['text'] as String;
    }
    return byBlock;
  }

  /// sentenceId → playback bounds for the article's current narration asset.
  Map<String, ({int startMs, int endMs})> _narrationRanges(String articleId) {
    final rows = _db.select(
      'SELECT r.sentence_id, r.audio_start_ms, r.audio_end_ms '
      'FROM sentence_audio_ranges r '
      'JOIN narration_assets n ON n.narration_id = r.narration_id '
      'WHERE n.article_id = ? AND n.artifact_revision = '
      '(SELECT current_artifact_revision FROM articles WHERE article_id = ?)',
      [articleId, articleId],
    );
    return {
      for (final row in rows)
        row['sentence_id'] as String: (
          startMs: row['audio_start_ms'] as int,
          endMs: row['audio_end_ms'] as int,
        ),
    };
  }

  /// Rebuilds a typed block from the stored kind + payload. Legacy rows
  /// (payload '') and unrecognized kinds degrade to plain paragraphs so a
  /// pre-v4 article keeps rendering. Table translations are composed from
  /// the active translation set, never from the payload.
  static InstalledBlock _decodeBlock({
    required String blockId,
    required String kind,
    required int order,
    required String payloadJson,
    required List<InstalledSentence> sentences,
    Map<String, Map<String, String>> cellTranslations = const {},
  }) {
    // Legacy v3 rows carry the empty-string default: treat them as an empty
    // payload object so every field read below is a plain absent-optional.
    final payload = payloadJson.isEmpty
        ? <String, Object?>{}
        : jsonDecode(payloadJson);
    final r = JsonReader(payload, 'blocks($blockId).payload_json');
    switch (kind) {
      case 'heading':
        return InstalledTextBlock(
          blockId: blockId,
          order: order,
          kind: ArticleTextKind.heading,
          level: r.optional('level')?.asInt(min: 1, max: 6) ?? 1,
          sentences: sentences,
        );
      case 'list_item':
        final listKind = switch (r.optional('list_kind')?.asString()) {
          'ordered' => ArticleListKind.ordered,
          _ => ArticleListKind.bullet,
        };
        return InstalledTextBlock(
          blockId: blockId,
          order: order,
          kind: ArticleTextKind.listItem,
          listKind: listKind,
          listDepth: r.optional('list_depth')?.asInt(min: 0, max: 4) ?? 0,
          listOrdinal: r.optional('list_ordinal')?.asInt(min: 0),
          sentences: sentences,
        );
      case 'quote':
        return InstalledTextBlock(
          blockId: blockId,
          order: order,
          kind: ArticleTextKind.quote,
          quoteDepth: r.optional('quote_depth')?.asInt(min: 1, max: 4) ?? 1,
          sentences: sentences,
        );
      case 'table':
        final alignmentReaders =
            r.optional('alignments')?.asArray() ?? const <JsonReader>[];
        final alignments = [
          for (final ar in alignmentReaders)
            TableAlignmentWire.fromWire(ar.asString()) ??
                TableAlignment.inherit,
        ];
        final headerReaders =
            r.optional('header')?.asArray() ?? const <JsonReader>[];
        final header = [for (final cr in headerReaders) _decodeCell(cr)];
        final rowReaders =
            r.optional('rows')?.asArray() ?? const <JsonReader>[];
        final rows = [
          for (final rowReader in rowReaders)
            [for (final cr in rowReader.asArray()) _decodeCell(cr)],
        ];
        return InstalledTableBlock(
          blockId: blockId,
          order: order,
          alignments: alignments,
          header: header,
          rows: rows,
          translationById: cellTranslations[blockId] ?? const {},
        );
      case 'code':
        return InstalledCodeBlock(
          blockId: blockId,
          order: order,
          language: r
              .optional('language')
              ?.asStringOrNull(minLength: 1, maxLength: 64),
          code: r['code'].asString(),
        );
      case 'divider':
        return InstalledDividerBlock(blockId: blockId, order: order);
      case 'paragraph':
      default:
        return InstalledTextBlock(
          blockId: blockId,
          order: order,
          kind: ArticleTextKind.paragraph,
          sentences: sentences,
        );
    }
  }

  static InstalledTableCell _decodeCell(JsonReader cr) {
    final runReaders = cr.optional('runs')?.asArray() ?? const [];
    return InstalledTableCell(
      cellId: cr['cell_id'].asString(),
      text: cr['text'].asString(),
      runs: [
        for (final rr in runReaders)
          ArticleRun(
            kind:
                ArticleRunKind.fromWire(rr['kind'].asString()) ??
                ArticleRunKind.plain,
            text: rr['text'].asString(),
            href: rr.optional('href')?.asStringOrNull(),
          ),
      ],
    );
  }

  /// Sentence render runs; the legacy empty column decodes as one plain run
  /// of the whole sentence text (v1.0 normalization).
  static List<ArticleRun> decodeRuns(
    String renderJson, {
    required String fallbackText,
  }) {
    if (renderJson.isEmpty) {
      return [ArticleRun(kind: ArticleRunKind.plain, text: fallbackText)];
    }
    final readers = JsonReader(
      jsonDecode(renderJson),
      'render_json',
    ).asArray(maxItems: 2048);
    if (readers.isEmpty) {
      return [ArticleRun(kind: ArticleRunKind.plain, text: fallbackText)];
    }
    return [
      for (final rr in readers)
        ArticleRun(
          kind:
              ArticleRunKind.fromWire(rr['kind'].asString()) ??
              ArticleRunKind.plain,
          text: rr['text'].asString(),
          href: rr.optional('href')?.asStringOrNull(),
        ),
    ];
  }

  static String encodeRuns(List<ArticleRun> runs) => jsonEncode([
    for (final run in runs)
      {
        'kind': run.kind.wire,
        'text': run.text,
        if (run.href != null) 'href': run.href,
      },
  ]);

  static String _encodeTextPayload(ParsedTextBlock block) => jsonEncode({
    if (block.level != null) 'level': block.level,
    if (block.listKind != null) 'list_kind': block.listKind!.name,
    if (block.kind == ArticleTextKind.listItem) 'list_depth': block.listDepth,
    if (block.listOrdinal != null) 'list_ordinal': block.listOrdinal,
    if (block.kind == ArticleTextKind.quote) 'quote_depth': block.quoteDepth,
  });

  static Map<String, Object?> _encodeCell(ParsedTableCell cell) => {
    'cell_id': cell.cellId,
    'text': cell.text,
    'runs': [
      for (final run in cell.runs)
        {
          'kind': run.kind.wire,
          'text': run.text,
          if (run.href != null) 'href': run.href,
        },
    ],
  };

  /// The table payload stores source structure only; translations live in
  /// table_cell_translations (v5).
  static String _encodeTablePayload(ParsedTableBlock block) => jsonEncode({
    'alignments': [for (final a in block.alignments) a.wire],
    'header': [for (final cell in block.header) _encodeCell(cell)],
    'rows': [
      for (final row in block.rows) [for (final cell in row) _encodeCell(cell)],
    ],
  });

  ReadingMode? getReadingMode(String articleId) {
    final rows = _db.select(
      'SELECT mode FROM article_reading_mode WHERE article_id = ?',
      [articleId],
    );
    if (rows.isEmpty) return null;
    return ReadingMode.fromName(rows.first['mode'] as String);
  }

  void setReadingMode(String articleId, ReadingMode mode) {
    _db.execute(
      'INSERT INTO article_reading_mode (article_id, mode, updated_at) '
      'VALUES (?, ?, ?) '
      'ON CONFLICT(article_id) DO UPDATE SET mode = excluded.mode, '
      'updated_at = excluded.updated_at',
      [articleId, mode.name, DateTime.now().toUtc().toIso8601String()],
    );
  }

  /// Atomically replaces any previously installed revision of the article
  /// with the new validated package (MOB-IMP-002 pointer switch).
  ///
  /// Installs the immutable base plus its packaged derivatives: a complete
  /// zh-Hans translation set (activated) when the package carries one, and
  /// a narration asset when sentences bear audio ranges. Runs in one short
  /// transaction; callers move files first and keep the recovery log around
  /// this call (design §8.2).
  void installArticle({
    required ArticleContent content,
    required ReadpackManifest manifest,
    required String manifestJson,
    required String attributionJson,
  }) {
    final articleId = content.articleId;
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute('BEGIN IMMEDIATE');
    try {
      // Deleting the article row cascades to every base and derivative
      // table; snapshot the user's display-mode preference first and restore
      // it with the new row, so an upgrade does not reset it. The restore
      // stays inside this transaction: a post-commit restore could fail
      // after the commit landed and make the caller roll back a live
      // artifact.
      final previousMode = getReadingMode(articleId);
      _db.execute('DELETE FROM articles WHERE article_id = ?', [articleId]);
      _db.execute(
        'INSERT INTO articles (article_id, title, author, '
        'source_display_name, source_url, revision, origin, '
        'source_sha256, structure_sha256, parser_version, '
        'segmenter_version, current_artifact_revision, installed_at) '
        "VALUES (?, ?, ?, ?, ?, ?, 'catalog', ?, ?, ?, ?, ?, ?)",
        [
          articleId,
          content.title,
          content.source.author,
          content.source.displayName,
          content.source.url,
          content.revision,
          content.sourceSha256,
          content.structureSha256,
          null, // v1 manifests carry no parser identifier; segmenter below
          manifest.pipeline.segmenter,
          manifest.artifactRevision,
          now,
        ],
      );
      _db.execute(
        'INSERT INTO article_artifacts (article_id, artifact_revision, '
        'ingress_kind, package_id, format_version, size_bytes, sha256, '
        'manifest_json, attribution_json, installed_at) '
        "VALUES (?, ?, 'catalog', ?, ?, ?, ?, ?, ?, ?)",
        [
          articleId,
          manifest.artifactRevision,
          manifest.packageId,
          manifest.formatVersion,
          manifest.fileFor('audio/article.m4a').size,
          manifest.fileFor('audio/article.m4a').sha256,
          manifestJson,
          attributionJson,
          now,
        ],
      );
      if (previousMode != null) {
        setReadingMode(articleId, previousMode);
      }
      final blocks = [...content.blocks]..sort((a, b) => a.order - b.order);
      for (final block in blocks) {
        final described = _describe(block);
        _db.execute(
          'INSERT INTO blocks (article_id, block_id, kind, ord, payload_json) '
          'VALUES (?, ?, ?, ?, ?)',
          [
            articleId,
            block.blockId,
            described.kind,
            block.order,
            described.payload,
          ],
        );
        if (block is! ParsedTextBlock) continue;
        final sentences = [...block.sentences]
          ..sort((a, b) => a.order - b.order);
        for (final sentence in sentences) {
          _db.execute(
            'INSERT INTO sentences (article_id, block_id, sentence_id, ord, '
            'text, render_json) VALUES (?, ?, ?, ?, ?, ?)',
            [
              articleId,
              block.blockId,
              sentence.sentenceId,
              sentence.order,
              sentence.text,
              encodeRuns(sentence.runs),
            ],
          );
        }
      }
      _installPackagedDerivatives(
        content: content,
        manifest: manifest,
        now: now,
      );
      _db.execute('COMMIT');
    } catch (_) {
      // A failing ROLLBACK must not mask the original error.
      try {
        _db.execute('ROLLBACK');
      } catch (_) {
        // Ignored; the original exception is rethrown below.
      }
      rethrow;
    }
  }

  /// Writes the packaged translation set (activated when complete) and the
  /// narration asset. A v1 package always carries both; source-only inputs
  /// (phase 2) simply produce neither. Partial derivatives are never
  /// installed: the caller validated the package as a whole.
  void _installPackagedDerivatives({
    required ArticleContent content,
    required ReadpackManifest manifest,
    required String now,
  }) {
    final articleId = content.articleId;
    final sentenceTranslations = [
      for (final sentence in _textSentences(content))
        if (sentence.translationZh != null)
          (sentence.sentenceId, sentence.translationZh!),
    ];
    final tableTranslations = [
      for (final block in content.blocks)
        if (block is ParsedTableBlock)
          for (final entry in block.translationById.entries)
            (block.blockId, entry.key, entry.value),
    ];
    if (sentenceTranslations.isNotEmpty || tableTranslations.isNotEmpty) {
      final setId = newUuid();
      _db.execute(
        'INSERT INTO translation_sets (translation_set_id, article_id, '
        'artifact_revision, structure_sha256, target_locale, origin, '
        'status, pipeline_json, created_at) '
        "VALUES (?, ?, ?, ?, 'zh-Hans', 'packaged', 'complete', ?, ?)",
        [
          setId,
          articleId,
          manifest.artifactRevision,
          content.structureSha256,
          jsonEncode({
            'provider': manifest.pipeline.translationProvider,
            'model': manifest.pipeline.translationModel,
            'prompt': manifest.pipeline.translationPrompt,
            'thinking': manifest.pipeline.translationThinking,
            'reasoning_effort': manifest.pipeline.translationReasoningEffort,
          }),
          now,
        ],
      );
      for (final (sentenceId, text) in sentenceTranslations) {
        _db.execute(
          'INSERT INTO sentence_translations (translation_set_id, '
          'sentence_id, text) VALUES (?, ?, ?)',
          [setId, sentenceId, text],
        );
      }
      for (final (blockId, cellId, text) in tableTranslations) {
        _db.execute(
          'INSERT INTO table_cell_translations (translation_set_id, '
          'block_id, cell_id, text) VALUES (?, ?, ?, ?)',
          [setId, blockId, cellId, text],
        );
      }
      _db.execute(
        'INSERT INTO article_active_translations (article_id, '
        "target_locale, translation_set_id) VALUES (?, 'zh-Hans', ?)",
        [articleId, setId],
      );
    }

    final narratedSentences = [
      for (final sentence in _textSentences(content))
        if (sentence.hasAudio)
          (
            sentence.sentenceId,
            sentence.audioStartMs!,
            sentence.audioEndMs!,
            sentence.audioStartSample!,
            sentence.audioEndSample!,
          ),
    ];
    if (narratedSentences.isNotEmpty) {
      final narrationId = newUuid();
      final audio = manifest.audio;
      _db.execute(
        'INSERT INTO narration_assets (narration_id, article_id, '
        'artifact_revision, structure_sha256, audio_path, codec, '
        'sample_rate_hz, channels, duration_ms) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          narrationId,
          articleId,
          manifest.artifactRevision,
          content.structureSha256,
          audio.path,
          audio.codec,
          audio.sampleRateHz,
          audio.channels,
          audio.durationMs,
        ],
      );
      for (final (sentenceId, startMs, endMs, startSample, endSample)
          in narratedSentences) {
        _db.execute(
          'INSERT INTO sentence_audio_ranges (narration_id, sentence_id, '
          'audio_start_ms, audio_end_ms, audio_start_sample, '
          'audio_end_sample) VALUES (?, ?, ?, ?, ?, ?)',
          [narrationId, sentenceId, startMs, endMs, startSample, endSample],
        );
      }
    }
  }

  /// The article's text-block sentences in reading order (block order, then
  /// sentence order) — the single traversal installs use for every
  /// sentence-derived row.
  static Iterable<SentenceContent> _textSentences(ArticleContent content) {
    final blocks = [...content.blocks]..sort((a, b) => a.order - b.order);
    return [
      for (final block in blocks)
        if (block is ParsedTextBlock)
          ...([...block.sentences]..sort((a, b) => a.order - b.order)),
    ];
  }

  /// Wire kind + payload JSON for one parsed block.
  static ({String kind, String payload}) _describe(ParsedBlock block) {
    switch (block) {
      case ParsedTextBlock():
        return (kind: block.kind.wire, payload: _encodeTextPayload(block));
      case ParsedTableBlock():
        return (kind: 'table', payload: _encodeTablePayload(block));
      case ParsedCodeBlock():
        return (
          kind: 'code',
          payload: jsonEncode({
            if (block.language != null) 'language': block.language,
            'code': block.code,
          }),
        );
      case ParsedDividerBlock():
        return (kind: 'divider', payload: '{}');
    }
  }

  /// Exposed for tests: the wire kind and payload JSON for a parsed block.
  static ({String kind, String payload}) describeBlock(ParsedBlock block) =>
      _describe(block);

  /// Switches the article's active set for the set's locale. The set must
  /// be complete, belong to this article, bind the current structure hash
  /// and cover exactly the base sentences and table cells — a drifted set
  /// must never reach the reader (lightweight-readpack design §4.1).
  void activateTranslation(String articleId, String translationSetId) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final set = _db.select(
        'SELECT target_locale, status, structure_sha256 FROM '
        'translation_sets WHERE translation_set_id = ? AND article_id = ?',
        [translationSetId, articleId],
      );
      if (set.isEmpty) {
        throw StateError('activation.unknown_set: $translationSetId');
      }
      if (set.first['status'] != 'complete') {
        throw StateError('activation.not_complete: $translationSetId');
      }
      final baseHash = _db.select(
        'SELECT structure_sha256 FROM articles WHERE article_id = ?',
        [articleId],
      );
      final setHash = set.first['structure_sha256'] as String?;
      final articleHash = baseHash.isEmpty
          ? null
          : baseHash.first['structure_sha256'] as String?;
      // Pre-v5 rows carry NULL hashes on both sides; any known hash must
      // match exactly — text-similarity mapping is forbidden.
      if (setHash != null && articleHash != null && setHash != articleHash) {
        throw StateError('activation.structure_mismatch: $translationSetId');
      }
      final uncovered =
          _db.select(
                'SELECT '
                '(SELECT COUNT(*) FROM sentences s WHERE s.article_id = ?1 '
                'AND NOT EXISTS (SELECT 1 FROM sentence_translations t '
                'WHERE t.translation_set_id = ?2 '
                'AND t.sentence_id = s.sentence_id)) '
                '+ '
                '(SELECT COUNT(*) FROM sentence_translations t '
                'WHERE t.translation_set_id = ?2 '
                'AND NOT EXISTS (SELECT 1 FROM sentences s '
                'WHERE s.article_id = ?1 AND s.sentence_id = t.sentence_id)) '
                'AS n',
                [articleId, translationSetId],
              ).first['n']
              as int;
      if (uncovered > 0) {
        throw StateError('activation.sentence_coverage: $translationSetId');
      }
      final cellGaps =
          _db
                  .select(
                    r'''
        WITH base_cells AS (
          SELECT b.block_id AS block_id,
                 json_extract(h.value, '$.cell_id') AS cell_id
          FROM blocks b, json_each(b.payload_json, '$.header') h
          WHERE b.article_id = ?1 AND b.kind = 'table'
          UNION ALL
          SELECT b.block_id, json_extract(c.value, '$.cell_id')
          FROM blocks b, json_each(b.payload_json, '$.rows') r,
               json_each(r.value) c
          WHERE b.article_id = ?1 AND b.kind = 'table'
        )
        SELECT
          (SELECT COUNT(*) FROM base_cells bc WHERE NOT EXISTS (
             SELECT 1 FROM table_cell_translations t
             WHERE t.translation_set_id = ?2
               AND t.block_id = bc.block_id AND t.cell_id = bc.cell_id))
          +
          (SELECT COUNT(*) FROM table_cell_translations t
           WHERE t.translation_set_id = ?2 AND NOT EXISTS (
             SELECT 1 FROM base_cells bc
             WHERE bc.block_id = t.block_id AND bc.cell_id = t.cell_id))
          AS n
        ''',
                    [articleId, translationSetId],
                  )
                  .first['n']
              as int;
      if (cellGaps > 0) {
        throw StateError('activation.cell_coverage: $translationSetId');
      }
      _db.execute(
        'INSERT INTO article_active_translations (article_id, '
        'target_locale, translation_set_id) VALUES (?, ?, ?) '
        'ON CONFLICT(article_id, target_locale) DO UPDATE SET '
        'translation_set_id = excluded.translation_set_id',
        [articleId, set.first['target_locale'] as String, translationSetId],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void deleteArticle(String articleId) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      // Derivative/base tables cascade with the article row.
      _db.execute('DELETE FROM articles WHERE article_id = ?', [articleId]);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static InstalledArticle _articleFromRow(Row row) {
    final narrationPath = row['audio_path'] as String?;
    final narration = narrationPath == null
        ? null
        : InstalledNarrationSummary(
            audioPath: narrationPath,
            codec: row['codec'] as String,
            sampleRateHz: row['sample_rate_hz'] as int,
            channels: row['channels'] as int,
            durationMs: row['duration_ms'] as int,
          );
    return InstalledArticle(
      articleId: row['article_id'] as String,
      title: row['title'] as String,
      author: row['author'] as String?,
      sourceDisplayName: row['source_display_name'] as String?,
      sourceUrl: row['source_url'] as String?,
      revision: row['revision'] as int,
      artifactRevision: row['current_artifact_revision'] as int,
      packageId: row['package_id'] as String?,
      formatVersion: row['format_version'] as String,
      origin: row['origin'] as String,
      structureSha256: row['structure_sha256'] as String?,
      narration: narration,
      installedAt: DateTime.parse(row['installed_at'] as String).toLocal(),
    );
  }
}
