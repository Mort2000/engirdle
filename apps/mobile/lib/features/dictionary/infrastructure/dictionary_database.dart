import 'package:sqlite3/sqlite3.dart';

import '../domain/dictionary_models.dart';

/// Read-only access to a versioned dictionary SQLite resource (MOB-DIC-004).
///
/// Expected schema (built by the PC-side dictionary builder, G4):
///
/// ```sql
/// CREATE TABLE entries (
///   headword TEXT NOT NULL,
///   pos TEXT NOT NULL,
///   sense_id TEXT NOT NULL,   -- namespace-qualified, never shown in UI
///   gloss_en TEXT NOT NULL,
///   gloss_zh TEXT,
///   source_name TEXT NOT NULL,
///   ord INTEGER NOT NULL DEFAULT 0
/// );
/// CREATE TABLE forms (form TEXT NOT NULL, lemma TEXT NOT NULL);
/// ```
///
/// The query order (design §8.5): exact phrase → normalized form →
/// word-form table → lemma candidates. No contextual disambiguation.
class DictionaryDatabase {
  DictionaryDatabase._(this._db);

  final Database _db;

  /// Opens read-only; throws when the file is missing or not a database.
  static DictionaryDatabase openReadOnly(String path) =>
      DictionaryDatabase._(sqlite3.open(path, mode: OpenMode.readOnly));

  void close() => _db.close();

  List<DictionarySense> exact(String headword) => _queryEntries(
      'SELECT headword, pos, sense_id, gloss_en, gloss_zh, source_name '
      'FROM entries WHERE headword = ? ORDER BY pos, ord, source_name',
      [headword]);

  List<String> lemmasFor(String form) {
    try {
      final rows = _db.select(
          'SELECT DISTINCT lemma FROM forms WHERE form = ?', [form]);
      return [for (final row in rows) row['lemma'] as String];
    } on SqliteException {
      // Same degradation as _queryEntries: unexpected schema means no entries.
      return const [];
    }
  }

  List<DictionarySense> _queryEntries(String sql, List<Object?> args) {
    try {
      final rows = _db.select(sql, args);
      return [
        for (final row in rows)
          DictionarySense(
            senseId: row['sense_id'] as String,
            headword: row['headword'] as String,
            partOfSpeech: row['pos'] as String,
            glossEn: row['gloss_en'] as String,
            glossZh: row['gloss_zh'] as String?,
            sourceName: row['source_name'] as String,
          ),
      ];
    } on SqliteException {
      // A dictionary without the expected schema behaves as "no entries":
      // article features stay usable, lookup degrades to not-found.
      return const [];
    }
  }
}
