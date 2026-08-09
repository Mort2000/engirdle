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
    'startup removes an installed v1 resource but preserves vocabulary',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'dictionary_v1_cleanup_',
      );
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
      await dirs.ensureBaseLayout();
      final appDb = AppDatabase.inMemory();
      addTearDown(appDb.close);
      final manifestDao = DictionaryManifestDao(appDb.db);
      final oldDirectory = dirs.dictionaryDir('engirdle-en-zh', 1);
      await oldDirectory.create(recursive: true);
      final oldDatabase = File(p.join(oldDirectory.path, 'dictionary.db'));
      await oldDatabase.writeAsBytes([1, 2, 3]);
      manifestDao.activate(
        DictionaryResource(
          dictionaryId: 'engirdle-en-zh',
          revision: 1,
          path: oldDatabase.path,
          sizeBytes: 3,
          sha256: '0' * 64,
          databaseSizeBytes: 3,
          databaseSha256: '0' * 64,
          formatVersion: '1.0',
          schemaVersion: 1,
          displayName: 'Old Dictionary',
          generatedAt: '2026-08-08T00:00:00Z',
          builderName: 'old',
          builderVersion: '1.0.0',
          normalizationVersion: 'unicode-nfc-lower-v1',
          sources: const [],
          modifications: const [],
          manifestJson: jsonEncode({
            'format_version': '1.0',
            'schema_version': 1,
            'display_name': 'Old Dictionary',
          }),
        ),
      );
      appDb.db.execute(
        'INSERT INTO vocabulary VALUES '
        '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          'saved-v1',
          'mend',
          'mend',
          null,
          'verb',
          'oewn-2025/mend-v-1',
          'to repair',
          '修理',
          'Open English WordNet 2025',
          'engirdle-en-zh',
          1,
          'article',
          1,
          'sentence',
          'Mend it.',
          null,
          'Article',
          '2026-08-09T00:00:00Z',
        ],
      );
      final service = DictionaryService(
        manifestDao: manifestDao,
        directories: dirs,
      );
      addTearDown(service.dispose);

      expect(service.status.value.state, DictionaryResourceState.incompatible);
      await service.recover();

      expect(service.currentResource(), isNull);
      expect(service.status.value.state, DictionaryResourceState.unavailable);
      expect(await oldDirectory.exists(), isFalse);
      expect(
        appDb.db
            .select('SELECT vocabulary_id FROM vocabulary')
            .single['vocabulary_id'],
        'saved-v1',
      );
    },
  );

  test('startup preserves an unsupported future dictionary revision', () async {
    final temp = await Directory.systemTemp.createTemp(
      'dictionary_future_preserve_',
    );
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final dirs = AppDirectories(Directory(p.join(temp.path, 'app')));
    await dirs.ensureBaseLayout();
    final appDb = AppDatabase.inMemory();
    addTearDown(appDb.close);
    final manifestDao = DictionaryManifestDao(appDb.db);
    final futureDirectory = dirs.dictionaryDir('engirdle-en-zh', 3);
    await futureDirectory.create(recursive: true);
    final futureDatabase = File(p.join(futureDirectory.path, 'dictionary.db'));
    await futureDatabase.writeAsBytes([3]);
    manifestDao.activate(
      DictionaryResource(
        dictionaryId: 'engirdle-en-zh',
        revision: 3,
        path: futureDatabase.path,
        sizeBytes: 1,
        sha256: '3' * 64,
        databaseSizeBytes: 1,
        databaseSha256: '3' * 64,
        formatVersion: '3.0',
        schemaVersion: 3,
        displayName: 'Future Dictionary',
        generatedAt: '2026-08-09T00:00:00Z',
        builderName: 'future',
        builderVersion: '3.0.0',
        normalizationVersion: 'future',
        sources: const [],
        modifications: const [],
        manifestJson: jsonEncode({
          'format_version': '3.0',
          'schema_version': 3,
          'display_name': 'Future Dictionary',
        }),
      ),
    );
    final service = DictionaryService(
      manifestDao: manifestDao,
      directories: dirs,
    );
    addTearDown(service.dispose);

    expect(service.status.value.state, DictionaryResourceState.incompatible);
    await service.recover();

    expect(service.status.value.state, DictionaryResourceState.incompatible);
    expect(service.currentResource()?.revision, 3);
    expect(await futureDatabase.exists(), isTrue);
  });

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
      final package = await _buildPackage(temp, revision: 2);
      final descriptor = DictionaryPackageDescriptor(
        dictionaryId: 'engirdle-en-zh',
        revision: 2,
        formatVersion: '2.0',
        schemaVersion: 2,
        displayName: 'Engirdle OEWN / Chinese Open Wordnet Dictionary',
        sizeBytes: await package.length(),
        sha256: await sha256OfFile(package),
      );

      await service.install(
        LocalDictionaryPackageSource(descriptor: descriptor, package: package),
      );

      expect(service.status.value.state, DictionaryResourceState.available);
      final resource = service.currentResource()!;
      expect(resource.dictionaryId, 'engirdle-en-zh');
      expect(resource.revision, 2);
      expect(resource.sources.map((source) => source.sourceId), [
        'oewn-2025',
        'omw-cmn:2.0',
      ]);
      expect(
        resource.path,
        p.join(
          dirs.root.path,
          'dictionaries',
          'engirdle-en-zh',
          '2',
          'dictionary.db',
        ),
      );
      expect(await File(resource.path).exists(), isTrue);

      final lookup = service.lookup('  “Mended,”  ');
      expect(lookup, isA<DictionaryLookupFound>());
      final result = (lookup as DictionaryLookupFound).result;
      expect(result.lemma, 'mend');
      expect(result.senses, hasLength(1));
      expect(result.senses.single.sourceId, 'oewn-2025');
      expect(result.senses.single.glossEn, 'to repair something');
      expect(result.senses.single.glossZh, '修理；修补');
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
  formatVersion: '2.0',
  schemaVersion: 2,
  displayName: 'Engirdle OEWN / Chinese Open Wordnet Dictionary',
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
      pronunciation TEXT,
      synset_ili TEXT,
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
  db.execute('''
    CREATE TABLE sense_translations (
      sense_id TEXT NOT NULL REFERENCES entries(sense_id),
      source_sense_id TEXT NOT NULL,
      raw_lemma TEXT NOT NULL,
      display_lemma TEXT NOT NULL,
      source_id TEXT NOT NULL,
      ord INTEGER NOT NULL,
      PRIMARY KEY (sense_id, source_sense_id),
      UNIQUE (sense_id, display_lemma)
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
  db.execute(
    'CREATE INDEX idx_sense_translations_sense_order ON sense_translations('
    'sense_id, ord, source_sense_id)',
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
    '2',
  ]);
  db.execute('INSERT INTO dictionary_meta VALUES (?, ?)', [
    'normalization_version',
    'unicode-nfc-lower-v1',
  ]);
  db.execute('INSERT INTO dictionary_meta VALUES (?, ?)', [
    'translation_alignment',
    'exact-ili-v1',
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
      'i100',
      'oewn-2025',
      'Open English WordNet 2025',
      1,
      0,
      0,
    ],
  );
  db.execute('INSERT INTO sense_translations VALUES (?, ?, ?, ?, ?, ?)', [
    'oewn-2025/oewn-mend-v-1',
    'omw-cmn:2.0/omw-cmn-repair-1',
    '修理',
    '修理',
    'omw-cmn:2.0',
    0,
  ]);
  db.execute('INSERT INTO sense_translations VALUES (?, ?, ?, ?, ?, ?)', [
    'oewn-2025/oewn-mend-v-1',
    'omw-cmn:2.0/omw-cmn-mend-1',
    '修补',
    '修补',
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
        'i999',
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
    'format_version': '2.0',
    'dictionary_id': 'engirdle-en-zh',
    'revision': revision,
    'schema_version': 2,
    'display_name': 'Engirdle OEWN / Chinese Open Wordnet Dictionary',
    'generated_at': generatedAt,
    'builder': {'name': 'test-builder', 'version': '2.0.0'},
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
        id: 'omw-cmn:2.0',
        version: '2.0',
        name: 'Chinese Open Wordnet 2.0',
        license: 'Chinese Open Wordnet License',
      ),
    ],
    'modifications': ['normalized and source-preserving'],
    'license_files': ['licenses/oewn-2025.txt', 'licenses/omw-cmn-2.0.txt'],
    if (manifestPaddingBytes > 0) 'padding': 'x' * manifestPaddingBytes,
  };
  final zip = TestZipBuilder()
    ..addStored('manifest.json', utf8.encode(jsonEncode(manifest)))
    ..addStored('dictionary.db', await database.readAsBytes())
    ..addStored('licenses/oewn-2025.txt', utf8.encode('CC BY 4.0'))
    ..addStored(
      'licenses/omw-cmn-2.0.txt',
      utf8.encode('Chinese Open Wordnet License'),
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
  'direction': id == 'oewn-2025' ? 'en-en' : 'zh',
  'input': {
    'url': id == 'oewn-2025'
        ? 'https://en-word.net/static/english-wordnet-2025.xml.gz'
        : 'https://github.com/omwn/omw-data/releases/download/v2.0/'
              'omw-cmn-2.0.tar.xz',
    'sha256': id == 'oewn-2025'
        ? '9ca6d1dcb75f822fdd66617f7d9da48142ace38dd544d6ad5e2feca1674ad3fe'
        : '7d07af60a6ced0cedc4ca114d0b60a796d3f138df0f3be21f6322e53d004e91c',
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
            'Chinese Open Wordnet',
            'Open Multilingual Wordnet',
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
