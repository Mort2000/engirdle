import 'package:sqlite3/sqlite3.dart';

import '../../../contracts/readpack_v1/article.dart';
import '../../../contracts/readpack_v1/manifest.dart';
import '../domain/installed_article.dart';

/// DAO for library-owned tables: articles, blocks, sentences and
/// article_reading_mode. Raw JSON (manifest/attribution) is kept verbatim
/// for the attribution page; structured content is normalized into tables.
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
      'SELECT block_id, kind, ord FROM blocks WHERE article_id = ? ORDER BY ord',
      [articleId],
    );
    final sentenceRows = _db.select(
      'SELECT block_id, sentence_id, ord, text, translation_zh, '
      'audio_start_ms, audio_end_ms FROM sentences '
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
              translationZh: row['translation_zh'] as String?,
              audioStartMs: row['audio_start_ms'] as int?,
              audioEndMs: row['audio_end_ms'] as int?,
            ),
          );
    }
    return [
      for (final row in blockRows)
        InstalledBlock(
          blockId: row['block_id'] as String,
          kind: row['kind'] as String,
          order: row['ord'] as int,
          sentences: byBlock[row['block_id']] ?? const [],
        ),
    ];
  }

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
        _db.execute(
          'INSERT INTO blocks (article_id, block_id, kind, ord) '
          'VALUES (?, ?, ?, ?)',
          [articleId, block.blockId, block.kind, block.order],
        );
        final sentences = [...block.sentences]
          ..sort((a, b) => a.order - b.order);
        for (final sentence in sentences) {
          _db.execute(
            'INSERT INTO sentences (article_id, block_id, sentence_id, ord, '
            'text, translation_zh, audio_start_ms, audio_end_ms, '
            'audio_start_sample, audio_end_sample) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
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
