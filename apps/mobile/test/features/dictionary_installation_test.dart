import 'dart:convert';
import 'dart:io';

import 'package:engirdle_mobile/features/dictionary/application/dictionary_service.dart';
import 'package:engirdle_mobile/features/dictionary/domain/dictionary_models.dart';
import 'package:engirdle_mobile/features/dictionary/infrastructure/dictionary_dao.dart';
import 'package:engirdle_mobile/features/dictionary/infrastructure/dictionary_package_source.dart';
import 'package:engirdle_mobile/platform/crypto/sha256.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:engirdle_mobile/shared_kernel/failures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../helpers/test_zip_builder.dart';

void main() {
  test(
    'a validated package installs atomically and supports offline lookup',
    () async {
      final temp = await Directory.systemTemp.createTemp('dictionary_install_');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
      await dirs.ensureBaseLayout();
      final appDb = AppDatabase.inMemory();
      addTearDown(appDb.close);
      final service = DictionaryService(
        manifestDao: DictionaryManifestDao(appDb.db),
        directories: dirs,
      );
      addTearDown(service.dispose);
      final package = await _buildPackage(temp, revision: 1);
      final descriptor = DictionaryPackageDescriptor(
        dictionaryId: 'engirdle-en-zh',
        revision: 1,
        formatVersion: '1.0',
        schemaVersion: 1,
        displayName: 'Engirdle English–Chinese Offline Dictionary',
        sizeBytes: await package.length(),
        sha256: await sha256OfFile(package),
      );

      await service.install(
        LocalDictionaryPackageSource(descriptor: descriptor, package: package),
      );

      expect(service.status.value.state, DictionaryResourceState.available);
      final resource = service.currentResource()!;
      expect(resource.dictionaryId, 'engirdle-en-zh');
      expect(resource.revision, 1);
      expect(resource.sources.map((source) => source.sourceId), [
        'oewn-2025',
        'freedict-eng-zho-2025.11.23',
      ]);
      expect(
        resource.path,
        p.join(
          dirs.root.path,
          'dictionaries',
          'engirdle-en-zh',
          '1',
          'dictionary.db',
        ),
      );
      expect(await File(resource.path).exists(), isTrue);

      final lookup = service.lookup('  “Mended,”  ');
      expect(lookup, isA<DictionaryLookupFound>());
      final result = (lookup as DictionaryLookupFound).result;
      expect(result.lemma, 'mend');
      expect(result.senses.map((sense) => sense.sourceId), [
        'oewn-2025',
        'freedict-eng-zho-2025.11.23',
      ]);
      expect(result.senses.first.glossEn, 'to repair something');
      expect(result.senses.last.glossZh, '修理');
    },
  );

  test(
    'failed upgrades preserve the active revision and clean staging',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'dictionary_rollback_',
      );
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
      await dirs.ensureBaseLayout();
      final appDb = AppDatabase.inMemory();
      addTearDown(appDb.close);
      final service = DictionaryService(
        manifestDao: DictionaryManifestDao(appDb.db),
        directories: dirs,
      );
      addTearDown(service.dispose);
      final first = await _buildPackage(temp, revision: 1);
      await service.install(
        LocalDictionaryPackageSource(
          descriptor: await _descriptor(first, revision: 1),
          package: first,
        ),
      );
      final second = await _buildPackage(temp, revision: 2);
      final correct = await _descriptor(second, revision: 2);
      final wrongHash = DictionaryPackageDescriptor(
        dictionaryId: correct.dictionaryId,
        revision: correct.revision,
        formatVersion: correct.formatVersion,
        schemaVersion: correct.schemaVersion,
        displayName: correct.displayName,
        sizeBytes: correct.sizeBytes,
        sha256: '0' * 64,
      );

      await expectLater(
        service.install(
          LocalDictionaryPackageSource(descriptor: wrongHash, package: second),
        ),
        throwsA(isA<AppFailure>()),
      );

      expect(service.currentResource()!.revision, 1);
      expect(service.lookup('mend'), isA<DictionaryLookupFound>());
      final staging = await dirs.stagingRoot.list().toList();
      expect(staging.whereType<Directory>(), isEmpty);
    },
  );

  test('a failed first install remains unavailable', () async {
    final temp = await Directory.systemTemp.createTemp(
      'dictionary_first_install_failure_',
    );
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
    await dirs.ensureBaseLayout();
    final appDb = AppDatabase.inMemory();
    addTearDown(appDb.close);
    final service = DictionaryService(
      manifestDao: DictionaryManifestDao(appDb.db),
      directories: dirs,
    );
    addTearDown(service.dispose);
    final package = await _buildPackage(temp, revision: 1);
    final correct = await _descriptor(package, revision: 1);
    final wrongHash = DictionaryPackageDescriptor(
      dictionaryId: correct.dictionaryId,
      revision: correct.revision,
      formatVersion: correct.formatVersion,
      schemaVersion: correct.schemaVersion,
      displayName: correct.displayName,
      sizeBytes: correct.sizeBytes,
      sha256: '0' * 64,
    );

    await expectLater(
      service.install(
        LocalDictionaryPackageSource(descriptor: wrongHash, package: package),
      ),
      throwsA(isA<AppFailure>()),
    );

    expect(service.currentResource(), isNull);
    expect(service.status.value.state, DictionaryResourceState.unavailable);
  });

  test('an unknown package path is rejected before activation', () async {
    final temp = await Directory.systemTemp.createTemp(
      'dictionary_unknown_path_',
    );
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
    await dirs.ensureBaseLayout();
    final appDb = AppDatabase.inMemory();
    addTearDown(appDb.close);
    final service = DictionaryService(
      manifestDao: DictionaryManifestDao(appDb.db),
      directories: dirs,
    );
    addTearDown(service.dispose);
    final package = await _buildPackage(
      temp,
      revision: 2,
      extraPath: 'unexpected.bin',
    );

    await expectLater(
      service.install(
        LocalDictionaryPackageSource(
          descriptor: await _descriptor(package, revision: 2),
          package: package,
        ),
      ),
      throwsA(isA<AppFailure>()),
    );

    expect(service.currentResource(), isNull);
    expect(service.status.value.state, DictionaryResourceState.incompatible);
  });

  test(
    'startup recovery removes dictionary staging and unreferenced revisions',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'dictionary_recovery_',
      );
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
      await dirs.ensureBaseLayout();
      final appDb = AppDatabase.inMemory();
      addTearDown(appDb.close);
      final service = DictionaryService(
        manifestDao: DictionaryManifestDao(appDb.db),
        directories: dirs,
      );
      addTearDown(service.dispose);
      final package = await _buildPackage(temp, revision: 1);
      await service.install(
        LocalDictionaryPackageSource(
          descriptor: await _descriptor(package, revision: 1),
          package: package,
        ),
      );
      final orphan = dirs.dictionaryDir('engirdle-en-zh', 99);
      await orphan.create(recursive: true);
      await File(p.join(orphan.path, 'dictionary.db')).writeAsBytes([1]);
      final staging = dirs.dictionaryStagingDir(
        '11111111-1111-4111-8111-111111111111',
      );
      await staging.create(recursive: true);
      await File(p.join(staging.path, 'partial')).writeAsBytes([1]);

      await service.recover();

      expect(await orphan.exists(), isFalse);
      expect(await staging.exists(), isFalse);
      expect(await File(service.currentResource()!.path).exists(), isTrue);
    },
  );

  test(
    'a package cannot impersonate a formal source with another version',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'dictionary_source_version_',
      );
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
      await dirs.ensureBaseLayout();
      final appDb = AppDatabase.inMemory();
      addTearDown(appDb.close);
      final service = DictionaryService(
        manifestDao: DictionaryManifestDao(appDb.db),
        directories: dirs,
      );
      addTearDown(service.dispose);
      final package = await _buildPackage(
        temp,
        revision: 1,
        oewnVersion: '2025+',
      );

      await expectLater(
        service.install(
          LocalDictionaryPackageSource(
            descriptor: await _descriptor(package, revision: 1),
            package: package,
          ),
        ),
        throwsA(isA<AppFailure>()),
      );

      expect(service.currentResource(), isNull);
    },
  );

  test(
    'different package bytes cannot replace the same immutable revision',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'dictionary_immutable_',
      );
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
      await dirs.ensureBaseLayout();
      final appDb = AppDatabase.inMemory();
      addTearDown(appDb.close);
      final service = DictionaryService(
        manifestDao: DictionaryManifestDao(appDb.db),
        directories: dirs,
      );
      addTearDown(service.dispose);
      final firstRoot = Directory(p.join(temp.path, 'first'))..createSync();
      final secondRoot = Directory(p.join(temp.path, 'second'))..createSync();
      final first = await _buildPackage(firstRoot, revision: 1);
      await service.install(
        LocalDictionaryPackageSource(
          descriptor: await _descriptor(first, revision: 1),
          package: first,
        ),
      );
      final second = await _buildPackage(
        secondRoot,
        revision: 1,
        generatedAt: '2026-08-09T01:00:00Z',
      );

      await expectLater(
        service.install(
          LocalDictionaryPackageSource(
            descriptor: await _descriptor(second, revision: 1),
            package: second,
          ),
        ),
        throwsA(isA<AppFailure>()),
      );

      expect(service.currentResource()!.sha256, await sha256OfFile(first));
      expect(service.status.value.state, DictionaryResourceState.available);
    },
  );

  test(
    'a structurally valid database with an empty sense is rejected',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'dictionary_empty_sense_',
      );
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
      await dirs.ensureBaseLayout();
      final appDb = AppDatabase.inMemory();
      addTearDown(appDb.close);
      final service = DictionaryService(
        manifestDao: DictionaryManifestDao(appDb.db),
        directories: dirs,
      );
      addTearDown(service.dispose);
      final package = await _buildPackage(
        temp,
        revision: 1,
        includeEmptySense: true,
      );

      await expectLater(
        service.install(
          LocalDictionaryPackageSource(
            descriptor: await _descriptor(package, revision: 1),
            package: package,
          ),
        ),
        throwsA(isA<AppFailure>()),
      );

      expect(service.currentResource(), isNull);
    },
  );

  test('a manifest above its per-entry limit is rejected', () async {
    final temp = await Directory.systemTemp.createTemp(
      'dictionary_large_manifest_',
    );
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
    await dirs.ensureBaseLayout();
    final appDb = AppDatabase.inMemory();
    addTearDown(appDb.close);
    final service = DictionaryService(
      manifestDao: DictionaryManifestDao(appDb.db),
      directories: dirs,
    );
    addTearDown(service.dispose);
    final package = await _buildPackage(
      temp,
      revision: 1,
      manifestPaddingBytes: 1024 * 1024 + 1,
    );

    await expectLater(
      service.install(
        LocalDictionaryPackageSource(
          descriptor: await _descriptor(package, revision: 1),
          package: package,
        ),
      ),
      throwsA(isA<AppFailure>()),
    );

    expect(service.currentResource(), isNull);
  });

  test('an installed resource cannot be downgraded', () async {
    final temp = await Directory.systemTemp.createTemp('dictionary_downgrade_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
    await dirs.ensureBaseLayout();
    final appDb = AppDatabase.inMemory();
    addTearDown(appDb.close);
    final service = DictionaryService(
      manifestDao: DictionaryManifestDao(appDb.db),
      directories: dirs,
    );
    addTearDown(service.dispose);
    final revisionTwoRoot = Directory(p.join(temp.path, 'r2'))..createSync();
    final revisionOneRoot = Directory(p.join(temp.path, 'r1'))..createSync();
    final revisionTwo = await _buildPackage(revisionTwoRoot, revision: 2);
    final revisionOne = await _buildPackage(revisionOneRoot, revision: 1);
    await service.install(
      LocalDictionaryPackageSource(
        descriptor: await _descriptor(revisionTwo, revision: 2),
        package: revisionTwo,
      ),
    );

    await expectLater(
      service.install(
        LocalDictionaryPackageSource(
          descriptor: await _descriptor(revisionOne, revision: 1),
          package: revisionOne,
        ),
      ),
      throwsA(isA<AppFailure>()),
    );

    expect(service.currentResource()!.revision, 2);
    expect(service.lookup('mend'), isA<DictionaryLookupFound>());
  });

  test(
    'a corrupt installed database can be repaired from the same revision',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'dictionary_same_revision_repair_',
      );
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
      await dirs.ensureBaseLayout();
      final appDb = AppDatabase.inMemory();
      addTearDown(appDb.close);
      final service = DictionaryService(
        manifestDao: DictionaryManifestDao(appDb.db),
        directories: dirs,
      );
      addTearDown(service.dispose);
      final package = await _buildPackage(temp, revision: 1);
      final descriptor = await _descriptor(package, revision: 1);
      final installed = await service.install(
        LocalDictionaryPackageSource(descriptor: descriptor, package: package),
      );
      await File(installed.path).writeAsBytes([1, 2, 3], flush: true);
      expect(service.lookup('mend'), isA<DictionaryLookupResourceError>());
      expect(service.status.value.state, DictionaryResourceState.corrupt);

      await service.install(
        LocalDictionaryPackageSource(descriptor: descriptor, package: package),
      );

      expect(service.status.value.state, DictionaryResourceState.available);
      expect(service.lookup('mend'), isA<DictionaryLookupFound>());
    },
  );
}

Future<DictionaryPackageDescriptor> _descriptor(
  File package, {
  required int revision,
}) async => DictionaryPackageDescriptor(
  dictionaryId: 'engirdle-en-zh',
  revision: revision,
  formatVersion: '1.0',
  schemaVersion: 1,
  displayName: 'Engirdle English–Chinese Offline Dictionary',
  sizeBytes: await package.length(),
  sha256: await sha256OfFile(package),
);

Future<File> _buildPackage(
  Directory root, {
  required int revision,
  String? extraPath,
  String oewnVersion = '2025',
  String generatedAt = '2026-08-09T00:00:00Z',
  bool includeEmptySense = false,
  int manifestPaddingBytes = 0,
}) async {
  final database = File(p.join(root.path, 'dictionary-$revision.db'));
  final db = sqlite3.open(database.path);
  db.execute('''
    CREATE TABLE entries (
      headword TEXT NOT NULL,
      normalized_headword TEXT NOT NULL,
      pos TEXT NOT NULL,
      sense_id TEXT PRIMARY KEY,
      gloss_en TEXT,
      gloss_zh TEXT,
      pronunciation TEXT,
      source_id TEXT NOT NULL,
      source_name TEXT NOT NULL,
      pos_rank INTEGER NOT NULL,
      source_rank INTEGER NOT NULL,
      ord INTEGER NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE forms (
      form TEXT NOT NULL,
      normalized_form TEXT NOT NULL,
      lemma TEXT NOT NULL,
      source_id TEXT NOT NULL,
      pos TEXT,
      source_rank INTEGER NOT NULL,
      ord INTEGER NOT NULL,
      PRIMARY KEY (normalized_form, lemma, source_id, pos)
    ) WITHOUT ROWID
  ''');
  db.execute(
    'CREATE TABLE dictionary_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
  db.execute(
    'CREATE INDEX idx_entries_headword_order ON entries('
    'headword, source_rank, pos_rank, ord, sense_id)',
  );
  db.execute(
    'CREATE INDEX idx_entries_normalized_order ON entries('
    'normalized_headword, source_rank, pos_rank, ord, sense_id)',
  );
  db.execute(
    'CREATE INDEX idx_forms_normalized_order ON forms('
    'normalized_form, source_rank, ord, lemma)',
  );
  db.execute('INSERT INTO dictionary_meta VALUES (?, ?)', [
    'dictionary_id',
    'engirdle-en-zh',
  ]);
  db.execute('INSERT INTO dictionary_meta VALUES (?, ?)', [
    'revision',
    revision.toString(),
  ]);
  db.execute('INSERT INTO dictionary_meta VALUES (?, ?)', [
    'schema_version',
    '1',
  ]);
  db.execute('INSERT INTO dictionary_meta VALUES (?, ?)', [
    'normalization_version',
    'unicode-nfc-lower-v1',
  ]);
  db.execute(
    'INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      'mend',
      'mend',
      'verb',
      'oewn-2025/oewn-mend-v-1',
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
      'mend',
      'mend',
      'verb',
      'freedict-eng-zho-2025.11.23/mend-v-1',
      null,
      '修理',
      'mɛnd',
      'freedict-eng-zho-2025.11.23',
      'FreeDict English–Chinese 2025.11.23',
      1,
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
  if (includeEmptySense) {
    db.execute(
      'INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'empty',
        'empty',
        'noun',
        'oewn-2025/empty-n-1',
        null,
        null,
        null,
        'oewn-2025',
        'Open English WordNet 2025',
        0,
        0,
        99,
      ],
    );
  }
  db.close();

  final manifest = {
    'format_version': '1.0',
    'dictionary_id': 'engirdle-en-zh',
    'revision': revision,
    'schema_version': 1,
    'display_name': 'Engirdle English–Chinese Offline Dictionary',
    'generated_at': generatedAt,
    'builder': {'name': 'test-builder', 'version': '1.0.0'},
    'normalization': {
      'algorithm': 'Unicode NFC, whitespace collapse and Unicode lowercase',
      'version': 'unicode-nfc-lower-v1',
    },
    'database': {
      'path': 'dictionary.db',
      'size': await database.length(),
      'sha256': await sha256OfFile(database),
    },
    'sources': [
      _source(
        id: 'oewn-2025',
        version: oewnVersion,
        name: 'Open English WordNet 2025',
        license: 'Creative Commons Attribution 4.0 International',
      ),
      _source(
        id: 'freedict-eng-zho-2025.11.23',
        version: '2025.11.23',
        name: 'FreeDict English–Chinese',
        license: 'Creative Commons Attribution-ShareAlike 3.0',
      ),
    ],
    'modifications': ['normalized and source-preserving'],
    'license_files': [
      'licenses/oewn-2025.txt',
      'licenses/freedict-eng-zho-2025.11.23.txt',
    ],
    if (manifestPaddingBytes > 0) 'padding': 'x' * manifestPaddingBytes,
  };
  final zip = TestZipBuilder()
    ..addStored('manifest.json', utf8.encode(jsonEncode(manifest)))
    ..addStored('dictionary.db', await database.readAsBytes())
    ..addStored('licenses/oewn-2025.txt', utf8.encode('CC BY 4.0'))
    ..addStored(
      'licenses/freedict-eng-zho-2025.11.23.txt',
      utf8.encode('CC BY-SA 3.0'),
    );
  if (extraPath != null) zip.addStored(extraPath, [1, 2, 3]);
  final package = File(p.join(root.path, 'dictionary-$revision.dictpack'));
  await package.writeAsBytes(zip.build(), flush: true);
  return package;
}

Map<String, Object> _source({
  required String id,
  required String version,
  required String name,
  required String license,
}) => {
  'source_id': id,
  'version': version,
  'display_name': name,
  'direction': id == 'oewn-2025' ? 'en-en' : 'en-zh',
  'input': {
    'url': id == 'oewn-2025'
        ? 'https://en-word.net/static/english-wordnet-2025.xml.gz'
        : 'https://download.freedict.org/dictionaries/eng-zho/2025.11.23/'
              'freedict-eng-zho-2025.11.23.src.tar.xz',
    'sha256': id == 'oewn-2025'
        ? '9ca6d1dcb75f822fdd66617f7d9da48142ace38dd544d6ad5e2feca1674ad3fe'
        : '78f6909786861809886201827e5e3d55dbf8e12f753d7a7183e785dbc574de8b',
  },
  'licenses': [
    {'name': license, 'url': 'https://example.invalid/license'},
    if (id == 'oewn-2025')
      {
        'name': 'Princeton WordNet License',
        'url': 'https://wordnet.princeton.edu/license-and-commercial-use',
      },
  ],
  'attributions': id == 'oewn-2025'
      ? [
          {
            'name': 'Open English WordNet',
            'url': 'https://github.com/globalwordnet/english-wordnet',
          },
          {
            'name': 'Princeton WordNet',
            'url': 'https://wordnet.princeton.edu/',
          },
        ]
      : [
          for (final attribution in const [
            'FreeDict',
            'WikDict',
            'DBnary',
            'Wiktionary',
          ])
            {
              'name': attribution,
              'url': 'https://example.invalid/$attribution',
            },
        ],
  'counts': {
    'original_headwords': 2,
    'filtered_headwords': 0,
    'final_headwords': 1,
  },
  'extraction_note': 'fixture extraction note',
};
