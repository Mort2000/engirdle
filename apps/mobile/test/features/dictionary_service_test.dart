import 'dart:io';

import 'package:engirdle_mobile/features/dictionary/application/dictionary_service.dart';
import 'package:engirdle_mobile/features/dictionary/domain/dictionary_models.dart';
import 'package:engirdle_mobile/features/dictionary/infrastructure/dictionary_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Offline dictionary lookup (MOB-DIC-001…004): selection cleanup, the
/// exact → normalized → forms → lemma query order, and degradation when the
/// resource is absent.
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
      expect(DictionaryService.normalizeSelection('mother-in-law'),
          'mother-in-law');
    });

    test('a pure-punctuation selection normalizes to empty', () {
      expect(DictionaryService.normalizeSelection('  …  '), '');
    });
  });

  group('lookup', () {
    late Directory temp;
    late AppDatabase appDb;
    late DictionaryManifestDao manifestDao;
    late DictionaryService service;
    late String dictionaryPath;

    Future<void> buildDictionaryFile() async {
      dictionaryPath = p.join(temp.path, 'dictionary.db');
      final db = sqlite3.open(dictionaryPath);
      db.execute('''
        CREATE TABLE entries (
          headword TEXT NOT NULL, pos TEXT NOT NULL, sense_id TEXT NOT NULL,
          gloss_en TEXT NOT NULL, gloss_zh TEXT, source_name TEXT NOT NULL,
          ord INTEGER NOT NULL DEFAULT 0
        )
      ''');
      db.execute(
          'CREATE TABLE forms (form TEXT NOT NULL, lemma TEXT NOT NULL)');
      db.execute(
        "INSERT INTO entries VALUES ('mend', 'verb', 'test.en/mend#v.1', "
        "'to repair something', '修理', 'TestDict', 0)",
      );
      db.execute(
        "INSERT INTO entries VALUES ('mend', 'noun', 'test.en/mend#n.1', "
        "'a repaired place', '修补处', 'TestDict', 0)",
      );
      db.execute("INSERT INTO forms VALUES ('mended', 'mend')");
      db.execute("INSERT INTO forms VALUES ('mending', 'mend')");
      db.close();
    }

    Future<void> installResource() async {
      manifestDao.save(DictionaryResource(
        dictionaryId: 'testdict',
        revision: 3,
        path: dictionaryPath,
        sizeBytes: await File(dictionaryPath).length(),
        sha256: '0' * 64,
        displayName: 'Test Dictionary',
        sources: const ['TestSource'],
        modifications: null,
      ));
    }

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('dict_test_');
      await buildDictionaryFile();
      appDb = AppDatabase.inMemory();
      manifestDao = DictionaryManifestDao(appDb.db);
      service = DictionaryService(manifestDao: manifestDao);
    });

    tearDown(() async {
      service.dispose();
      appDb.close();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('returns null (unavailable) when no resource is installed', () {
      expect(service.available, isFalse);
      expect(service.lookup('mend'), isNull);
    });

    test('exact lookup returns all senses ordered by part of speech', () async {
      await installResource();
      final result = service.lookup('mend')!;
      expect(result.found, isTrue);
      expect(result.lemma, isNull);
      expect(result.senses, hasLength(2));
      expect(result.senses.first.partOfSpeech, 'noun');
      expect(result.senses.last.partOfSpeech, 'verb');
      expect(result.senses.first.glossZh, '修补处');
    });

    test('an inflected form resolves through the forms table to its lemma',
        () async {
      await installResource();
      final result = service.lookup('mended')!;
      expect(result.found, isTrue);
      expect(result.lemma, 'mend');
      expect(result.senses, hasLength(2));
    });

    test('selection cleanup plus case folding feeds the lookup', () async {
      await installResource();
      final result = service.lookup('  “Mended,”  ')!;
      expect(result.surface, 'Mended');
      expect(result.normalized, 'mended');
      expect(result.lemma, 'mend');
      expect(result.found, isTrue);
    });

    test('unknown words yield an empty result, never a fabricated gloss',
        () async {
      await installResource();
      final result = service.lookup('zebra')!;
      expect(result.found, isFalse);
      expect(result.senses, isEmpty);
      expect(result.lemma, isNull);
    });

    test('a dictionary file with an unexpected schema degrades to not-found',
        () async {
      final weirdPath = p.join(temp.path, 'weird.db');
      final weird = sqlite3.open(weirdPath);
      weird.execute('CREATE TABLE something_else (x TEXT)');
      weird.close();
      manifestDao.save(DictionaryResource(
        dictionaryId: 'weird',
        revision: 1,
        path: weirdPath,
        sizeBytes: 1,
        sha256: '0' * 64,
        displayName: 'Weird',
        sources: const [],
        modifications: null,
      ));
      final result = service.lookup('mend')!;
      expect(result.found, isFalse);
    });
  });
}
