import 'dart:convert';
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
        manifestDao.activate(_v2Resource(path ?? dictionaryPath));

    test('uninstalled is distinct from not-found', () {
      expect(service.lookup('mend'), isA<DictionaryLookupUnavailable>());
      activate();
      final lookup = service.lookup('zebra');
      expect(lookup, isA<DictionaryLookupNotFound>());
      expect((lookup as DictionaryLookupNotFound).result.senses, isEmpty);
    });

    test('an OEWN sense includes its ordered Chinese lemmas', () {
      activate();
      final result = (service.lookup('mend') as DictionaryLookupFound).result;
      expect(result.lemma, isNull);
      expect(result.senses, hasLength(1));
      expect(result.senses.single.sourceId, 'oewn-2025');
      expect(
        result.senses.single.translations.map((item) => item.displayLemma),
        ['修理', '修补的'],
      );
      expect(result.senses.single.translations.last.rawLemma, '修补+的');
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
      manifestDao.activate(_v2Resource(weirdPath, revision: 2));
      expect(service.lookup('mend'), isA<DictionaryLookupResourceError>());
      expect(service.status.value.state, DictionaryResourceState.corrupt);
    });
  });
}

void _buildDictionary(String path) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE entries (
      headword TEXT NOT NULL, normalized_headword TEXT NOT NULL,
      pos TEXT NOT NULL, sense_id TEXT PRIMARY KEY, gloss_en TEXT,
      pronunciation TEXT, synset_ili TEXT, source_id TEXT NOT NULL,
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
  db.execute('''
    CREATE TABLE sense_translations (
      sense_id TEXT NOT NULL, source_sense_id TEXT NOT NULL,
      raw_lemma TEXT NOT NULL, display_lemma TEXT NOT NULL,
      source_id TEXT NOT NULL, ord INTEGER NOT NULL
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
      'i100',
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
      'i101',
      'oewn-2025',
      'Open English WordNet 2025',
      0,
      0,
      0,
    ],
  );
  db.execute('INSERT INTO sense_translations VALUES (?, ?, ?, ?, ?, ?)', [
    'oewn/mend-v-1',
    'omw-cmn:2.0/repair-1',
    '修理',
    '修理',
    'omw-cmn:2.0',
    0,
  ]);
  db.execute('INSERT INTO sense_translations VALUES (?, ?, ?, ?, ?, ?)', [
    'oewn/mend-v-1',
    'omw-cmn:2.0/mended-1',
    '修补+的',
    '修补的',
    'omw-cmn:2.0',
    1,
  ]);
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

DictionaryResource _v2Resource(String path, {int revision = 1}) =>
    DictionaryResource(
      dictionaryId: 'engirdle-en-zh',
      revision: revision,
      path: path,
      sizeBytes: 1,
      sha256: '0' * 64,
      databaseSizeBytes: 1,
      databaseSha256: '0' * 64,
      formatVersion: '2.0',
      schemaVersion: 2,
      displayName: 'Test Dictionary',
      generatedAt: '',
      builderName: 'test',
      builderVersion: 'test',
      normalizationVersion: 'unicode-nfc-lower-v1',
      sources: const [],
      modifications: const [],
      manifestJson: jsonEncode(_manifest(revision)),
    );

Map<String, Object> _manifest(int revision) => {
  'format_version': '2.0',
  'dictionary_id': 'engirdle-en-zh',
  'revision': revision,
  'schema_version': 2,
  'display_name': 'Test Dictionary',
  'generated_at': '2026-08-09T00:00:00Z',
  'builder': {'name': 'test', 'version': '2.0.0'},
  'normalization': {
    'algorithm': 'NFC lowercase',
    'version': 'unicode-nfc-lower-v1',
  },
  'database': {'path': 'dictionary.db', 'size': 1, 'sha256': '0' * 64},
  'sources': [_oewnSource, _omwSource],
  'modifications': ['fixture'],
  'license_files': ['licenses/oewn-2025.txt', 'licenses/omw-cmn-2.0.txt'],
};

final _oewnSource = {
  'source_id': 'oewn-2025',
  'version': '2025',
  'display_name': 'Open English WordNet 2025',
  'direction': 'en-en',
  'input': {
    'url': 'https://en-word.net/static/english-wordnet-2025.xml.gz',
    'sha256':
        '9ca6d1dcb75f822fdd66617f7d9da48142ace38dd544d6ad5e2feca1674ad3fe',
  },
  'licenses': [
    {
      'name': 'Creative Commons Attribution 4.0 International',
      'url': 'https://creativecommons.org/licenses/by/4.0/',
    },
    {
      'name': 'Princeton WordNet License',
      'url': 'https://wordnet.princeton.edu/license-and-commercial-use',
    },
  ],
  'attributions': [
    {
      'name': 'Open English WordNet',
      'url': 'https://github.com/globalwordnet/english-wordnet',
    },
    {'name': 'Princeton WordNet', 'url': 'https://wordnet.princeton.edu/'},
  ],
  'counts': _counts,
  'extraction_note': 'fixture',
};

final _omwSource = {
  'source_id': 'omw-cmn:2.0',
  'version': '2.0',
  'display_name': 'Chinese Open Wordnet 2.0',
  'direction': 'zh',
  'input': {
    'url':
        'https://github.com/omwn/omw-data/releases/download/v2.0/'
        'omw-cmn-2.0.tar.xz',
    'sha256':
        '7d07af60a6ced0cedc4ca114d0b60a796d3f138df0f3be21f6322e53d004e91c',
  },
  'licenses': [
    {
      'name': 'Chinese Open Wordnet License',
      'url': 'https://github.com/omwn/omw-data/blob/main/wns/cow/LICENSE',
    },
  ],
  'attributions': [
    {'name': 'Chinese Open Wordnet', 'url': 'https://bond-lab.github.io/cow/'},
    {'name': 'Open Multilingual Wordnet', 'url': 'https://omwn.org/'},
  ],
  'counts': _counts,
  'extraction_note': 'fixture',
};

const _counts = {
  'original_headwords': 1,
  'filtered_headwords': 0,
  'final_headwords': 1,
};
