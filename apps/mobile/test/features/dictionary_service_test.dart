import 'dart:io';

import 'package:engirdle_mobile/features/dictionary/application/dictionary_service.dart';
import 'package:engirdle_mobile/features/dictionary/domain/dictionary_models.dart';
import 'package:engirdle_mobile/features/dictionary/infrastructure/dictionary_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  group('normalizeSelection', () {
    test('trims whitespace and edge punctuation without touching content', () {
      expect(DictionaryService.normalizeSelection('  "Hello,"  '), 'Hello');
      expect(DictionaryService.normalizeSelection('word.'), 'word');
      expect(DictionaryService.normalizeSelection('（中文）'), '中文');
      expect(DictionaryService.normalizeSelection('well-known!'), 'well-known');
    });

    test('keeps inner punctuation', () {
      expect(DictionaryService.normalizeSelection("don't"), "don't");
      expect(
        DictionaryService.normalizeSelection('mother-in-law'),
        'mother-in-law',
      );
    });

    test('a pure-punctuation selection normalizes to empty', () {
      expect(DictionaryService.normalizeSelection('  …  '), '');
    });

    test('lookup keys normalize NFC, lowercase and internal whitespace', () {
      expect(DictionaryService.normalizeLookupKey('Take  \n OFF'), 'take off');
      expect(DictionaryService.normalizeLookupKey('A\u030A'), 'å');
    });
  });

  group('lookup states', () {
    late Directory temp;
    late AppDatabase appDb;
    late DictionaryManifestDao manifestDao;
    late DictionaryService service;
    late String dictionaryPath;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('dict_lookup_');
      final dirs = AppDirectories(temp);
      await dirs.ensureBaseLayout();
      dictionaryPath = p.join(temp.path, 'dictionary.db');
      _buildDictionary(dictionaryPath);
      appDb = AppDatabase.inMemory();
      manifestDao = DictionaryManifestDao(appDb.db);
      service = DictionaryService(manifestDao: manifestDao, directories: dirs);
    });

    tearDown(() async {
      service.dispose();
      appDb.close();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    void activate([String? path]) =>
        manifestDao.activate(_legacyResource(path ?? dictionaryPath));

    test('uninstalled is distinct from not-found', () {
      expect(service.lookup('mend'), isA<DictionaryLookupUnavailable>());
      activate();
      final lookup = service.lookup('zebra');
      expect(lookup, isA<DictionaryLookupNotFound>());
      expect((lookup as DictionaryLookupNotFound).result.senses, isEmpty);
    });

    test('exact results use explicit source and POS ranks', () {
      activate();
      final result = (service.lookup('mend') as DictionaryLookupFound).result;
      expect(result.lemma, isNull);
      expect(result.senses, hasLength(2));
      expect(result.senses.first.sourceId, 'oewn-2025');
      expect(result.senses.last.sourceId, 'freedict-eng-zho-2025.11.23');
    });

    test('normalization and a word form resolve to the lemma', () {
      activate();
      final result =
          (service.lookup('  “Mended,”  ') as DictionaryLookupFound).result;
      expect(result.surface, 'Mended');
      expect(result.normalized, 'mended');
      expect(result.lemma, 'mend');
    });

    test('an exact entry keeps meaningful edge punctuation', () {
      activate();
      final result =
          (service.lookup("  'hood  ") as DictionaryLookupFound).result;
      expect(result.surface, "'hood");
      expect(result.senses.single.headword, "'hood");
    });

    test('missing and invalid databases are resource errors', () {
      activate(p.join(temp.path, 'missing.db'));
      expect(service.lookup('mend'), isA<DictionaryLookupResourceError>());

      final weirdPath = p.join(temp.path, 'weird.db');
      final weird = sqlite3.open(weirdPath)
        ..execute('CREATE TABLE wrong (x TEXT)');
      weird.close();
      manifestDao.activate(_legacyResource(weirdPath, revision: 2));
      expect(service.lookup('mend'), isA<DictionaryLookupResourceError>());
    });
  });
}

void _buildDictionary(String path) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE entries (
      headword TEXT NOT NULL, normalized_headword TEXT NOT NULL,
      pos TEXT NOT NULL, sense_id TEXT PRIMARY KEY, gloss_en TEXT,
      gloss_zh TEXT, pronunciation TEXT, source_id TEXT NOT NULL,
      source_name TEXT NOT NULL, pos_rank INTEGER NOT NULL,
      source_rank INTEGER NOT NULL, ord INTEGER NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE forms (
      form TEXT NOT NULL, normalized_form TEXT NOT NULL, lemma TEXT NOT NULL,
      source_id TEXT NOT NULL, pos TEXT, source_rank INTEGER NOT NULL,
      ord INTEGER NOT NULL
    )
  ''');
  db.execute(
    'INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      'mend',
      'mend',
      'verb',
      'oewn/mend-v-1',
      'to repair something',
      null,
      null,
      'oewn-2025',
      'Open English WordNet 2025',
      1,
      0,
      0,
    ],
  );
  db.execute(
    'INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      "'hood",
      "'hood",
      'noun',
      'oewn/hood-n-1',
      'a state or condition',
      null,
      null,
      'oewn-2025',
      'Open English WordNet 2025',
      0,
      0,
      0,
    ],
  );
  db.execute(
    'INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      'mend',
      'mend',
      'noun',
      'freedict/mend-n-1',
      null,
      '修补处',
      null,
      'freedict-eng-zho-2025.11.23',
      'FreeDict',
      0,
      1,
      0,
    ],
  );
  db.execute('INSERT INTO forms VALUES (?, ?, ?, ?, ?, ?, ?)', [
    'mended',
    'mended',
    'mend',
    'oewn-2025',
    'verb',
    0,
    0,
  ]);
  db.close();
}

DictionaryResource _legacyResource(String path, {int revision = 1}) =>
    DictionaryResource(
      dictionaryId: 'engirdle-en-zh',
      revision: revision,
      path: path,
      sizeBytes: 1,
      sha256: '0' * 64,
      databaseSizeBytes: 1,
      databaseSha256: '0' * 64,
      formatVersion: 'legacy',
      schemaVersion: 0,
      displayName: 'Test Dictionary',
      generatedAt: '',
      builderName: 'test',
      builderVersion: 'test',
      normalizationVersion: 'legacy',
      sources: const [],
      modifications: const [],
      manifestJson: '{"display_name":"Test Dictionary"}',
    );
