import 'package:sqlite3/sqlite3.dart';

import '../../../shared_kernel/content_identity.dart';
import '../domain/vocabulary_entry.dart';

/// DAO for the `vocabulary` table (owned by the vocabulary feature).
/// No FK to articles: snapshots must survive article deletion.
class VocabularyDao {
  const VocabularyDao(this._db);

  final Database _db;

  static const _cols =
      'vocabulary_id, surface, normalized, lemma, part_of_speech, sense_id, '
      'sense_en, sense_zh, source_name, dictionary_id, dictionary_revision, '
      'article_id, revision, sentence_id, sentence_text, '
      'sentence_translation_zh, article_title, created_at';

  void insert(VocabularyEntry entry) {
    _db.execute(
      'INSERT INTO vocabulary ($_cols) VALUES '
      '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        entry.vocabularyId,
        entry.surface,
        entry.normalized,
        entry.lemma,
        entry.partOfSpeech,
        entry.senseId,
        entry.senseEn,
        entry.senseZh,
        entry.sourceName,
        entry.dictionaryId,
        entry.dictionaryRevision,
        entry.ref.articleId,
        entry.ref.revision,
        entry.ref.sentenceId,
        entry.sentenceText,
        entry.sentenceTranslationZh,
        entry.articleTitle,
        entry.createdAt.toUtc().toIso8601String(),
      ],
    );
  }

  void delete(String vocabularyId) {
    _db.execute('DELETE FROM vocabulary WHERE vocabulary_id = ?', [
      vocabularyId,
    ]);
  }

  /// Default order: newest first (design 假设⑤).
  List<VocabularyEntry> list() {
    final rows = _db.select(
      'SELECT $_cols FROM vocabulary ORDER BY created_at DESC, rowid DESC',
    );
    return [for (final row in rows) _fromRow(row)];
  }

  VocabularyEntry? byId(String vocabularyId) {
    final rows = _db.select(
      'SELECT $_cols FROM vocabulary WHERE vocabulary_id = ?',
      [vocabularyId],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  int countForArticle(String articleId) {
    final rows = _db.select(
      'SELECT COUNT(*) AS n FROM vocabulary WHERE article_id = ?',
      [articleId],
    );
    return rows.first['n'] as int;
  }

  Set<String> senseIdsForContext({
    required String dictionaryId,
    required int dictionaryRevision,
    required SentenceRef ref,
  }) {
    final rows = _db.select(
      'SELECT DISTINCT sense_id FROM vocabulary '
      'WHERE dictionary_id = ? AND dictionary_revision = ? '
      'AND article_id = ? AND revision = ? AND sentence_id = ?',
      [
        dictionaryId,
        dictionaryRevision,
        ref.articleId,
        ref.revision,
        ref.sentenceId,
      ],
    );
    return {for (final row in rows) row['sense_id'] as String};
  }

  static VocabularyEntry _fromRow(Row row) => VocabularyEntry(
    vocabularyId: row['vocabulary_id'] as String,
    surface: row['surface'] as String,
    normalized: row['normalized'] as String,
    lemma: row['lemma'] as String?,
    partOfSpeech: row['part_of_speech'] as String?,
    senseId: row['sense_id'] as String,
    senseEn: row['sense_en'] as String?,
    senseZh: row['sense_zh'] as String?,
    sourceName: row['source_name'] as String,
    dictionaryId: row['dictionary_id'] as String,
    dictionaryRevision: row['dictionary_revision'] as int,
    ref: SentenceRef(
      articleId: row['article_id'] as String,
      revision: row['revision'] as int,
      sentenceId: row['sentence_id'] as String,
    ),
    sentenceText: row['sentence_text'] as String,
    sentenceTranslationZh: row['sentence_translation_zh'] as String?,
    articleTitle: row['article_title'] as String,
    createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
  );
}
