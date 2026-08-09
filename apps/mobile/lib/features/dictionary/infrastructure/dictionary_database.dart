import 'package:sqlite3/sqlite3.dart';

import '../domain/dictionary_models.dart';

class DictionaryDatabase {
  DictionaryDatabase._(this._db);

  final Database _db;

  static DictionaryDatabase openReadOnly(String path) {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    db.execute('PRAGMA query_only = ON');
    return DictionaryDatabase._(db);
  }

  void close() => _db.close();

  List<DictionarySense> exact(String headword) => _queryEntries(
    'SELECT headword, pos, sense_id, gloss_en, gloss_zh, pronunciation, '
    'source_id, source_name FROM entries WHERE headword = ? '
    'ORDER BY source_rank, pos_rank, ord, sense_id',
    [headword],
  );

  List<DictionarySense> normalized(String normalizedHeadword) => _queryEntries(
    'SELECT headword, pos, sense_id, gloss_en, gloss_zh, pronunciation, '
    'source_id, source_name FROM entries WHERE normalized_headword = ? '
    'ORDER BY source_rank, pos_rank, ord, sense_id',
    [normalizedHeadword],
  );

  List<String> lemmasFor(String normalizedForm) {
    final rows = _db.select(
      'SELECT DISTINCT lemma, source_rank, ord FROM forms '
      'WHERE normalized_form = ? ORDER BY source_rank, ord, lemma',
      [normalizedForm],
    );
    return [for (final row in rows) row['lemma'] as String];
  }

  List<DictionarySense> _queryEntries(String sql, List<Object?> args) {
    final rows = _db.select(sql, args);
    return [
      for (final row in rows)
        DictionarySense(
          senseId: row['sense_id'] as String,
          headword: row['headword'] as String,
          partOfSpeech: row['pos'] as String,
          glossEn: row['gloss_en'] as String?,
          glossZh: row['gloss_zh'] as String?,
          pronunciation: row['pronunciation'] as String?,
          sourceId: row['source_id'] as String,
          sourceName: row['source_name'] as String,
        ),
    ];
  }
}
