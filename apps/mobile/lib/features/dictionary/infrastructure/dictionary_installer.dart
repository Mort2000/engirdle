import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../../contracts/contract_violation.dart';
import '../../../contracts/dictionary_v2/manifest.dart';
import '../../../platform/crypto/sha256.dart';
import '../../../platform/filesystem/app_directories.dart';
import '../../../platform/http/lan_http_client.dart';
import '../../../platform/logging/app_logger.dart';
import '../../../platform/zip/secure_zip_reader.dart';
import '../../../shared_kernel/failures.dart';
import '../../../shared_kernel/id_generator.dart';
import '../domain/dictionary_models.dart';
import 'dictionary_dao.dart';
import 'dictionary_package_source.dart';

class DictionaryInstaller {
  DictionaryInstaller({
    required DictionaryManifestDao manifestDao,
    required AppDirectories directories,
    SecureZipReader zipReader = const SecureZipReader(),
    AppLogger logger = const AppLogger('dictionary-installer'),
  }) : _manifestDao = manifestDao,
       _directories = directories,
       _zipReader = zipReader,
       _logger = logger;

  static const maxPackageBytes = 512 * 1024 * 1024;
  static const maxDatabaseBytes = 512 * 1024 * 1024;
  static const maxManifestBytes = 1024 * 1024;
  static const maxLicenseBytes = 1024 * 1024;
  static const maxExpandedBytes = 640 * 1024 * 1024;
  static const maxEntries = 16;

  static const _requiredTables = {
    'entries',
    'forms',
    'sense_translations',
    'dictionary_meta',
  };
  static const _requiredIndexes = {
    'idx_entries_headword_order',
    'idx_entries_normalized_order',
    'idx_forms_normalized_order',
    'idx_sense_translations_sense_order',
  };

  final DictionaryManifestDao _manifestDao;
  final AppDirectories _directories;
  final SecureZipReader _zipReader;
  final AppLogger _logger;

  Future<DictionaryResource> install(
    DictionaryPackageSource source, {
    required void Function() beforeActivate,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final descriptor = source.descriptor;
    final staging = _directories.dictionaryStagingDir(newUuid());
    final package = File(p.join(staging.path, 'resource.dictpack'));
    var moved = false;
    var closedBeforeActivation = false;
    void closeBeforeActivation() {
      if (closedBeforeActivation) return;
      beforeActivate();
      closedBeforeActivation = true;
    }

    try {
      if (descriptor.sizeBytes > maxPackageBytes) {
        throw const AppFailure(
          FailureKind.resourceLimit,
          'dictionary package too large',
        );
      }
      _rejectDowngrade(descriptor);
      await source.copyTo(
        package,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      await _validateOuter(package, descriptor);
      final entries = await _zipReader.preflight(package);
      _validateArchiveEntries(entries);

      final manifestEntry = entries.singleWhere(
        (entry) => entry.path == 'manifest.json',
      );
      final manifestFile = File(p.join(staging.path, 'manifest.json'));
      await _zipReader.extractEntry(package, manifestEntry, manifestFile);
      final manifestJson = await manifestFile.readAsString();
      final manifest = DictionaryManifest.parse(jsonDecode(manifestJson));
      _matchDescriptor(manifest, descriptor);
      final matchesInstalledArtifact = _validateInstalledRevision(descriptor);
      _validateLicenseSet(entries, manifest);

      for (final entry in entries) {
        if (entry.path == 'manifest.json') continue;
        await _zipReader.extractEntry(
          package,
          entry,
          File(p.join(staging.path, entry.path)),
        );
      }
      final database = File(p.join(staging.path, 'dictionary.db'));
      if (await database.length() != manifest.databaseSize ||
          await sha256OfFile(database) != manifest.databaseSha256) {
        throw const AppFailure(
          FailureKind.packageFormat,
          'dictionary database hash mismatch',
        );
      }
      _preflightDatabase(database, manifest);

      final finalDirectory = _directories.dictionaryDir(
        manifest.dictionaryId,
        manifest.revision,
      );
      final finalDatabase = File(p.join(finalDirectory.path, 'dictionary.db'));
      if (await finalDirectory.exists()) {
        final databaseMatches =
            await finalDatabase.exists() &&
            await sha256OfFile(finalDatabase) == manifest.databaseSha256;
        if (!databaseMatches) {
          if (!matchesInstalledArtifact) {
            throw const AppFailure(
              FailureKind.packageFormat,
              'immutable dictionary revision already exists with different content',
            );
          }
          // This exact package is already recorded, so replacing its damaged
          // database is a repair. Android's POSIX rename atomically swaps the
          // preflighted file into the path held by the active pointer.
          closeBeforeActivation();
          await database.rename(finalDatabase.path);
        }
      } else {
        await package.delete();
        await finalDirectory.parent.create(recursive: true);
        await staging.rename(finalDirectory.path);
        moved = true;
      }
      final resource = manifest.toResource(
        path: finalDatabase.path,
        packageSize: descriptor.sizeBytes,
        packageSha256: descriptor.sha256,
        manifestJson: manifestJson,
      );
      closeBeforeActivation();
      _manifestDao.activate(resource);
      await _cleanupInactive(resource);
      return resource;
    } on AppFailure {
      rethrow;
    } on ContractViolation catch (error) {
      throw AppFailure(
        FailureKind.packageFormat,
        'invalid dictionary manifest',
        detail: error.toString(),
      );
    } on SqliteException catch (error) {
      throw AppFailure(
        FailureKind.database,
        'dictionary database validation failed',
        detail: error.message,
      );
    } on FileSystemException catch (error) {
      throw AppFailure(
        FailureKind.download,
        'dictionary file operation failed',
        detail: error.message,
      );
    } on StateError catch (error) {
      throw AppFailure(
        FailureKind.packageFormat,
        'dictionary activation conflict',
        detail: error.message,
      );
    } finally {
      if (!moved && await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (error) {
          _logger.warn('dictionary.staging_cleanup_failed', {
            'error': '$error',
          });
        }
      }
    }
  }

  Future<void> recover() async {
    if (await _directories.stagingRoot.exists()) {
      await for (final entity in _directories.stagingRoot.list()) {
        if (entity is Directory &&
            p.basename(entity.path).startsWith('dictionary-')) {
          try {
            await entity.delete(recursive: true);
          } catch (error) {
            _logger.warn('dictionary.recover_staging_failed', {
              'error': '$error',
            });
          }
        }
      }
    }
    var active = _manifestDao.current();
    if (active != null && _isInstalledV1(active)) {
      await _removeIncompatible(active);
      active = _manifestDao.current();
    }
    if (active != null && !_isSupported(active)) return;
    if (active != null) await _cleanupInactive(active);
    await _cleanupOrphanDirectories(active);
  }

  static bool _isSupported(DictionaryResource resource) =>
      resource.formatVersion.startsWith('2.') && resource.schemaVersion == 2;

  static bool _isInstalledV1(DictionaryResource resource) =>
      resource.formatVersion.startsWith('1.') && resource.schemaVersion == 1;

  Future<void> _removeIncompatible(DictionaryResource resource) async {
    final expectedDirectory = _directories.dictionaryDir(
      resource.dictionaryId,
      resource.revision,
    );
    final expectedDatabase = p.join(expectedDirectory.path, 'dictionary.db');
    if (!p.equals(p.normalize(resource.path), p.normalize(expectedDatabase))) {
      throw const AppFailure(
        FailureKind.packageFormat,
        'incompatible dictionary path is outside its recorded revision',
      );
    }
    final entityType = await FileSystemEntity.type(
      expectedDirectory.path,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.directory) {
      await expectedDirectory.delete(recursive: true);
    } else if (entityType != FileSystemEntityType.notFound) {
      throw const AppFailure(
        FailureKind.packageFormat,
        'incompatible dictionary revision is not a regular directory',
      );
    }
    _manifestDao.removeInstallation(resource.dictionaryId, resource.revision);
  }

  Future<void> _validateOuter(
    File package,
    DictionaryPackageDescriptor descriptor,
  ) async {
    final actualSize = await package.length();
    if (actualSize != descriptor.sizeBytes) {
      throw const AppFailure(
        FailureKind.download,
        'dictionary package size mismatch',
      );
    }
    if (await sha256OfFile(package) != descriptor.sha256) {
      throw const AppFailure(
        FailureKind.download,
        'dictionary package sha256 mismatch',
      );
    }
  }

  static void _validateArchiveEntries(List<ZipEntryInfo> entries) {
    if (entries.length < 4 || entries.length > maxEntries) {
      throw const AppFailure(
        FailureKind.resourceLimit,
        'invalid dictionary entry count',
      );
    }
    var expanded = 0;
    final paths = <String>{};
    for (final entry in entries) {
      paths.add(entry.path);
      expanded += entry.uncompressedSize;
      final allowed =
          entry.path == 'manifest.json' ||
          entry.path == 'dictionary.db' ||
          RegExp(
            r'^licenses/[A-Za-z0-9][A-Za-z0-9._-]*\.txt$',
          ).hasMatch(entry.path);
      if (!allowed) {
        throw AppFailure(
          FailureKind.packageFormat,
          'unapproved dictionary path',
          detail: entry.path,
        );
      }
      if (entry.path == 'dictionary.db' &&
          entry.uncompressedSize > maxDatabaseBytes) {
        throw const AppFailure(
          FailureKind.resourceLimit,
          'dictionary database too large',
        );
      }
      if (entry.path == 'manifest.json' &&
          entry.uncompressedSize > maxManifestBytes) {
        throw const AppFailure(
          FailureKind.resourceLimit,
          'dictionary manifest too large',
        );
      }
      if (entry.path.startsWith('licenses/') &&
          entry.uncompressedSize > maxLicenseBytes) {
        throw const AppFailure(
          FailureKind.resourceLimit,
          'dictionary license notice too large',
        );
      }
    }
    if (!paths.containsAll({'manifest.json', 'dictionary.db'}) ||
        expanded > maxExpandedBytes) {
      throw const AppFailure(
        FailureKind.resourceLimit,
        'dictionary expansion limit exceeded',
      );
    }
  }

  static void _validateLicenseSet(
    List<ZipEntryInfo> entries,
    DictionaryManifest manifest,
  ) {
    final actual = entries
        .map((entry) => entry.path)
        .where((path) => path.startsWith('licenses/'))
        .toSet();
    if (actual.length != manifest.licenseFiles.length ||
        !actual.containsAll(manifest.licenseFiles)) {
      throw const AppFailure(
        FailureKind.packageFormat,
        'dictionary license set mismatch',
      );
    }
  }

  static void _matchDescriptor(
    DictionaryManifest manifest,
    DictionaryPackageDescriptor descriptor,
  ) {
    if (manifest.dictionaryId != descriptor.dictionaryId ||
        manifest.revision != descriptor.revision ||
        manifest.formatVersion != descriptor.formatVersion ||
        manifest.schemaVersion != descriptor.schemaVersion ||
        manifest.displayName != descriptor.displayName) {
      throw const AppFailure(
        FailureKind.packageFormat,
        'dictionary identity mismatch with catalog',
      );
    }
  }

  bool _validateInstalledRevision(DictionaryPackageDescriptor descriptor) {
    for (final installed in _manifestDao.installed()) {
      if (installed.dictionaryId == descriptor.dictionaryId &&
          installed.revision == descriptor.revision) {
        if (installed.sizeBytes != descriptor.sizeBytes ||
            installed.sha256 != descriptor.sha256) {
          throw const AppFailure(
            FailureKind.packageFormat,
            'immutable dictionary revision already has different package bytes',
          );
        }
        return true;
      }
    }
    return false;
  }

  void _rejectDowngrade(DictionaryPackageDescriptor descriptor) {
    final active = _manifestDao.current();
    if (active != null &&
        active.dictionaryId == descriptor.dictionaryId &&
        descriptor.revision < active.revision) {
      throw const AppFailure(
        FailureKind.packageFormat,
        'dictionary revision cannot be downgraded',
      );
    }
  }

  static void _preflightDatabase(File file, DictionaryManifest manifest) {
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      db.execute('PRAGMA query_only = ON');
      final check = db.select('PRAGMA quick_check');
      if (check.length != 1 || check.single.values.single != 'ok') {
        throw const AppFailure(
          FailureKind.database,
          'dictionary quick_check failed',
        );
      }
      final schema = db.select(
        "SELECT type, name FROM sqlite_master WHERE type IN ('table', 'index')",
      );
      final tables = {
        for (final row in schema.where((row) => row['type'] == 'table'))
          row['name'] as String,
      };
      final indexes = {
        for (final row in schema.where((row) => row['type'] == 'index'))
          row['name'] as String,
      };
      if (!tables.containsAll(_requiredTables) ||
          !indexes.containsAll(_requiredIndexes)) {
        throw const AppFailure(
          FailureKind.database,
          'dictionary schema objects missing',
        );
      }
      final metadata = {
        for (final row in db.select('SELECT key, value FROM dictionary_meta'))
          row['key'] as String: row['value'] as String,
      };
      if (metadata['dictionary_id'] != manifest.dictionaryId ||
          metadata['revision'] != manifest.revision.toString() ||
          metadata['schema_version'] != manifest.schemaVersion.toString() ||
          metadata['normalization_version'] != manifest.normalizationVersion ||
          metadata['translation_alignment'] != 'exact-ili-v1') {
        throw const AppFailure(
          FailureKind.database,
          'dictionary metadata mismatch',
        );
      }
      // Verify required v2 columns through harmless indexed queries.
      db.select(
        'SELECT headword, normalized_headword, pos, sense_id, gloss_en, '
        'pronunciation, synset_ili, source_id, source_name, pos_rank, '
        'source_rank, ord '
        'FROM entries WHERE normalized_headword = ? LIMIT 1',
        ['__engirdle_preflight__'],
      );
      db.select(
        'SELECT form, normalized_form, lemma, source_id, pos, source_rank, ord '
        'FROM forms WHERE normalized_form = ? LIMIT 1',
        ['__engirdle_preflight__'],
      );
      db.select(
        'SELECT sense_id, source_sense_id, raw_lemma, display_lemma, '
        'source_id, ord FROM sense_translations WHERE sense_id = ? LIMIT 1',
        ['__engirdle_preflight__'],
      );
      final sourceIds = manifest.sources
          .map((source) => source.sourceId)
          .toSet();
      final entrySources = db
          .select('SELECT DISTINCT source_id FROM entries')
          .map((row) => row['source_id'] as String)
          .toSet();
      final formSources = db
          .select('SELECT DISTINCT source_id FROM forms')
          .map((row) => row['source_id'] as String)
          .toSet();
      final translationSources = db
          .select('SELECT DISTINCT source_id FROM sense_translations')
          .map((row) => row['source_id'] as String)
          .toSet();
      if (!entrySources.every((source) => source == 'oewn-2025') ||
          !formSources.every((source) => source == 'oewn-2025') ||
          !translationSources.every((source) => source == 'omw-cmn:2.0') ||
          !sourceIds.containsAll({
            ...entrySources,
            ...formSources,
            ...translationSources,
          })) {
        throw const AppFailure(
          FailureKind.database,
          'dictionary rows contain an unregistered source',
        );
      }
      if (db.select('''
        SELECT 1
        FROM entries
        WHERE NULLIF(TRIM(gloss_en), '') IS NULL
        LIMIT 1
      ''').isNotEmpty) {
        throw const AppFailure(
          FailureKind.database,
          'dictionary contains an empty English sense',
        );
      }
      if (db.select('''
        SELECT 1
        FROM entries
        WHERE sense_id NOT LIKE source_id || '/%'
        LIMIT 1
      ''').isNotEmpty) {
        throw const AppFailure(
          FailureKind.database,
          'dictionary sense id is outside its source namespace',
        );
      }
      if (db.select('''
        SELECT 1
        FROM sense_translations
        WHERE source_sense_id NOT LIKE source_id || '/%'
           OR NULLIF(TRIM(raw_lemma), '') IS NULL
           OR NULLIF(TRIM(display_lemma), '') IS NULL
        LIMIT 1
      ''').isNotEmpty) {
        throw const AppFailure(
          FailureKind.database,
          'dictionary contains invalid Chinese lemma provenance',
        );
      }
      if (db.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw const AppFailure(
          FailureKind.database,
          'dictionary translation references an unknown sense',
        );
      }
    } finally {
      db.close();
    }
  }

  Future<void> _cleanupInactive(DictionaryResource active) async {
    for (final installed in _manifestDao.installed()) {
      if (installed.dictionaryId == active.dictionaryId &&
          installed.revision == active.revision) {
        continue;
      }
      final directory = _directories.dictionaryDir(
        installed.dictionaryId,
        installed.revision,
      );
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        _manifestDao.deleteInstallation(
          installed.dictionaryId,
          installed.revision,
        );
      } catch (error) {
        _logger.warn('dictionary.old_revision_cleanup_failed', {
          'dictionary_id': installed.dictionaryId,
          'revision': installed.revision,
          'error': '$error',
        });
      }
    }
  }

  Future<void> _cleanupOrphanDirectories(DictionaryResource? active) async {
    if (active == null || !await _directories.dictionaryRoot.exists()) return;
    final activeDirectory = p.normalize(p.dirname(active.path));
    await for (final dictionaryDirectory in _directories.dictionaryRoot.list(
      followLinks: false,
    )) {
      if (dictionaryDirectory is! Directory) continue;
      await for (final revisionDirectory in dictionaryDirectory.list(
        followLinks: false,
      )) {
        if (revisionDirectory is! Directory ||
            p.equals(p.normalize(revisionDirectory.path), activeDirectory)) {
          continue;
        }
        try {
          await revisionDirectory.delete(recursive: true);
        } catch (error) {
          _logger.warn('dictionary.orphan_revision_cleanup_failed', {
            'path': revisionDirectory.path,
            'error': '$error',
          });
        }
      }
      try {
        if (await dictionaryDirectory.list(followLinks: false).isEmpty) {
          await dictionaryDirectory.delete();
        }
      } catch (error) {
        _logger.warn('dictionary.empty_root_cleanup_failed', {
          'path': dictionaryDirectory.path,
          'error': '$error',
        });
      }
    }
  }
}
