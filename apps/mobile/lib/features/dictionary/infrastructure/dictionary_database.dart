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

  List<DictionarySense> exact(String headword) =>
      _queryEntries('e.headword = ?', headword);

  List<DictionarySense> normalized(String normalizedHeadword) =>
      _queryEntries('e.normalized_headword = ?', normalizedHeadword);

  List<String> lemmasFor(String normalizedForm) {
    final rows = _db.select(
      'SELECT DISTINCT lemma, source_rank, ord FROM forms '
      'WHERE normalized_form = ? ORDER BY source_rank, ord, lemma',
      [normalizedForm],
    );
    return [for (final row in rows) row['lemma'] as String];
  }

  List<DictionarySense> _queryEntries(String predicate, String value) {
    final rows = _db.select(
      'SELECT e.headword, e.pos, e.sense_id, e.gloss_en, e.pronunciation, '
      'e.source_id, e.source_name, t.source_sense_id, t.raw_lemma, '
      't.display_lemma, t.source_id AS translation_source_id '
      'FROM entries e LEFT JOIN sense_translations t ON t.sense_id = e.sense_id '
      'WHERE $predicate '
      'ORDER BY e.source_rank, e.pos_rank, e.ord, e.sense_id, '
      't.ord, t.source_sense_id',
      [value],
    );
    final accumulators = <String, _SenseAccumulator>{};
    for (final row in rows) {
      final senseId = row['sense_id'] as String;
      final accumulator = accumulators.putIfAbsent(
        senseId,
        () => _SenseAccumulator(
          senseId: senseId,
          headword: row['headword'] as String,
          partOfSpeech: row['pos'] as String,
          glossEn: row['gloss_en'] as String?,
          pronunciation: row['pronunciation'] as String?,
          sourceId: row['source_id'] as String,
          sourceName: row['source_name'] as String,
        ),
      );
      final sourceSenseId = row['source_sense_id'] as String?;
      if (sourceSenseId != null) {
        accumulator.translations.add(
          DictionaryTranslation(
            sourceSenseId: sourceSenseId,
            rawLemma: row['raw_lemma'] as String,
            displayLemma: row['display_lemma'] as String,
            sourceId: row['translation_source_id'] as String,
          ),
        );
      }
    }
    return [
      for (final accumulator in accumulators.values) accumulator.toSense(),
    ];
  }
}

class _SenseAccumulator {
  _SenseAccumulator({
    required this.senseId,
    required this.headword,
    required this.partOfSpeech,
    required this.glossEn,
    required this.pronunciation,
    required this.sourceId,
    required this.sourceName,
  });

  final String senseId;
  final String headword;
  final String partOfSpeech;
  final String? glossEn;
  final String? pronunciation;
  final String sourceId;
  final String sourceName;
  final List<DictionaryTranslation> translations = [];

  DictionarySense toSense() => DictionarySense(
    senseId: senseId,
    headword: headword,
    partOfSpeech: partOfSpeech,
    glossEn: glossEn,
    translations: List.unmodifiable(translations),
    pronunciation: pronunciation,
    sourceId: sourceId,
    sourceName: sourceName,
  );
}
