import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../../contracts/contract_violation.dart';
import '../../../contracts/readpack_v1/article.dart';
import '../../../contracts/readpack_v1/manifest.dart';
import '../domain/installed_article.dart';

/// DAO for library-owned tables: articles, blocks, sentences and
/// article_reading_mode. Raw JSON (manifest/attribution) is kept verbatim
/// for the attribution page; structured content is normalized into tables.
///
/// The v1.1 block payload (heading/list/quote styling, table cells, code
/// bodies) and the sentence render runs live in JSON columns — JSON exists
/// only at this seam. Shapes:
///
///   blocks.payload_json:
///     text:    {"level":2} / {"list_kind":"bullet","list_depth":1,
///              "list_ordinal":3} / {"quote_depth":2} / {}
///     table:   {"alignments":["default"],"header":[cell],"rows":[[cell]],
///              "translation_zh":{"cell-id":"译文"}}
///     code:    {"language":"python","code":"..."}
///     divider: {}
///   sentences.render_json: [{"kind":"plain","text":"...","href":"..."}]
///
/// The empty string (the v4 column default for legacy rows) decodes as a
/// plain paragraph and a single plain run respectively.
class LibraryDao {
  const LibraryDao(this._db);

  final Database _db;

  List<InstalledArticle> listArticles() {
    final rows = _db.select(
      'SELECT article_id, title, author, source_display_name, source_url, '
      'revision, artifact_revision, package_id, format_version, duration_ms, '
      'installed_at FROM articles ORDER BY title COLLATE NOCASE',
    );
    return [for (final row in rows) _articleFromRow(row)];
  }

  InstalledArticle? getArticle(String articleId) {
    final rows = _db.select(
      'SELECT article_id, title, author, source_display_name, source_url, '
      'revision, artifact_revision, package_id, format_version, duration_ms, '
      'installed_at FROM articles WHERE article_id = ?',
      [articleId],
    );
    if (rows.isEmpty) return null;
    return _articleFromRow(rows.first);
  }

  /// Raw stored JSON for the attribution page; null when not installed.
  ({String manifestJson, String attributionJson})? getRawJson(String articleId) {
    final rows = _db.select(
      'SELECT manifest_json, attribution_json FROM articles WHERE article_id = ?',
      [articleId],
    );
    if (rows.isEmpty) return null;
    return (
      manifestJson: rows.first['manifest_json'] as String,
      attributionJson: rows.first['attribution_json'] as String,
    );
  }

  List<InstalledBlock> getBlocks(String articleId) {
    final blockRows = _db.select(
      'SELECT block_id, kind, ord, payload_json FROM blocks '
      'WHERE article_id = ? ORDER BY ord',
      [articleId],
    );
    final sentenceRows = _db.select(
      'SELECT block_id, sentence_id, ord, text, translation_zh, '
      'audio_start_ms, audio_end_ms, render_json FROM sentences '
      'WHERE article_id = ? ORDER BY ord',
      [articleId],
    );
    final byBlock = <String, List<InstalledSentence>>{};
    for (final row in sentenceRows) {
      byBlock.putIfAbsent(row['block_id'] as String, () => []).add(
            InstalledSentence(
              sentenceId: row['sentence_id'] as String,
              blockId: row['block_id'] as String,
              order: row['ord'] as int,
              text: row['text'] as String,
              runs: decodeRuns(row['render_json'] as String,
                  fallbackText: row['text'] as String),
              translationZh: row['translation_zh'] as String?,
              audioStartMs: row['audio_start_ms'] as int?,
              audioEndMs: row['audio_end_ms'] as int?,
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
        ),
    ];
  }

  /// Rebuilds a typed block from the stored kind + payload. Legacy rows
  /// (payload '') and unrecognized kinds degrade to plain paragraphs so a
  /// pre-v4 article keeps rendering.
  static InstalledBlock _decodeBlock({
    required String blockId,
    required String kind,
    required int order,
    required String payloadJson,
    required List<InstalledSentence> sentences,
  }) {
    // Legacy v3 rows carry the empty-string default: treat them as an empty
    // payload object so every field read below is a plain absent-optional.
    final payload =
        payloadJson.isEmpty ? <String, Object?>{} : jsonDecode(payloadJson);
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
        final header = [
          for (final cr in headerReaders) _decodeCell(cr),
        ];
        final rowReaders =
            r.optional('rows')?.asArray() ?? const <JsonReader>[];
        final rows = [
          for (final rowReader in rowReaders)
            [
              for (final cr in rowReader.asArray()) _decodeCell(cr),
            ],
        ];
        final translation = <String, String>{};
        final translationReader = r.optional('translation_zh');
        if (translationReader != null) {
          for (final entry in translationReader.asObject().entries) {
            if (entry.value is String) {
              translation[entry.key] = entry.value as String;
            }
          }
        }
        return InstalledTableBlock(
          blockId: blockId,
          order: order,
          alignments: alignments,
          header: header,
          rows: rows,
          translationById: translation,
        );
      case 'code':
        return InstalledCodeBlock(
          blockId: blockId,
          order: order,
          language: r.optional('language')?.asStringOrNull(
                minLength: 1,
                maxLength: 64,
              ),
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
            kind: ArticleRunKind.fromWire(rr['kind'].asString()) ??
                ArticleRunKind.plain,
            text: rr['text'].asString(),
            href: rr.optional('href')?.asStringOrNull(),
          ),
      ],
    );
  }

  /// Sentence render runs; the legacy empty column decodes as one plain run
  /// of the whole sentence text (v1.0 normalization).
  static List<ArticleRun> decodeRuns(String renderJson,
      {required String fallbackText}) {
    if (renderJson.isEmpty) {
      return [ArticleRun(kind: ArticleRunKind.plain, text: fallbackText)];
    }
    final readers = JsonReader(jsonDecode(renderJson), 'render_json')
        .asArray(maxItems: 2048);
    if (readers.isEmpty) {
      return [ArticleRun(kind: ArticleRunKind.plain, text: fallbackText)];
    }
    return [
      for (final rr in readers)
        ArticleRun(
          kind: ArticleRunKind.fromWire(rr['kind'].asString()) ??
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
        if (block.listKind != null)
          'list_kind': block.listKind!.name,
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

  static String _encodeTablePayload(ParsedTableBlock block) => jsonEncode({
        'alignments': [for (final a in block.alignments) a.wire],
        'header': [for (final cell in block.header) _encodeCell(cell)],
        'rows': [
          for (final row in block.rows)
            [for (final cell in row) _encodeCell(cell)],
        ],
        'translation_zh': block.translationById,
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
  /// Runs in one short transaction; callers move files first and keep the
  /// recovery log around this call (design §8.2).
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
      // Deleting the article row cascades to article_reading_mode; snapshot
      // the user's display-mode preference first and restore it with the
      // new row, so an upgrade does not reset it. The restore stays inside
      // this transaction: a post-commit restore could fail after the commit
      // landed and make the caller roll back a live artifact.
      final previousMode = getReadingMode(articleId);
      _db.execute('DELETE FROM sentences WHERE article_id = ?', [articleId]);
      _db.execute('DELETE FROM blocks WHERE article_id = ?', [articleId]);
      _db.execute('DELETE FROM articles WHERE article_id = ?', [articleId]);
      _db.execute(
        'INSERT INTO articles (article_id, title, author, '
        'source_display_name, source_url, revision, artifact_revision, '
        'package_id, format_version, duration_ms, audio_codec, '
        'sample_rate_hz, channels, size_bytes, sha256, installed_at, '
        'manifest_json, attribution_json) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          articleId,
          content.title,
          content.source.author,
          content.source.displayName,
          content.source.url,
          content.revision,
          manifest.artifactRevision,
          manifest.packageId,
          manifest.formatVersion,
          manifest.audio.durationMs,
          manifest.audio.codec,
          manifest.audio.sampleRateHz,
          manifest.audio.channels,
          manifest.fileFor('audio/article.m4a').size,
          manifest.fileFor('audio/article.m4a').sha256,
          now,
          manifestJson,
          attributionJson,
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
          [articleId, block.blockId, described.kind, block.order, described.payload],
        );
        if (block is! ParsedTextBlock) continue;
        final sentences = [...block.sentences]..sort((a, b) => a.order - b.order);
        for (final sentence in sentences) {
          _db.execute(
            'INSERT INTO sentences (article_id, block_id, sentence_id, ord, '
            'text, translation_zh, audio_start_ms, audio_end_ms, '
            'audio_start_sample, audio_end_sample, render_json) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
              articleId,
              block.blockId,
              sentence.sentenceId,
              sentence.order,
              sentence.text,
              sentence.translationZh,
              sentence.audioStartMs,
              sentence.audioEndMs,
              sentence.audioStartSample,
              sentence.audioEndSample,
              encodeRuns(sentence.runs),
            ],
          );
        }
      }
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

  void deleteArticle(String articleId) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      // blocks/sentences/reading_mode cascade with the article row.
      _db.execute('DELETE FROM articles WHERE article_id = ?', [articleId]);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static InstalledArticle _articleFromRow(Row row) => InstalledArticle(
        articleId: row['article_id'] as String,
        title: row['title'] as String,
        author: row['author'] as String?,
        sourceDisplayName: row['source_display_name'] as String?,
        sourceUrl: row['source_url'] as String?,
        revision: row['revision'] as int,
        artifactRevision: row['artifact_revision'] as int,
        packageId: row['package_id'] as String,
        formatVersion: row['format_version'] as String,
        durationMs: row['duration_ms'] as int,
        installedAt:
            DateTime.parse(row['installed_at'] as String).toLocal(),
      );
}
