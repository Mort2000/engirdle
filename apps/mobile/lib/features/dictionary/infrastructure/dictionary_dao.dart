import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../../contracts/dictionary_v2/manifest.dart';
import '../domain/dictionary_models.dart';

class DictionaryManifestDao {
  const DictionaryManifestDao(this._db);

  final Database _db;

  DictionaryResource? current() {
    final rows = _db.select('''
      SELECT m.dictionary_id, m.revision, m.path, m.package_size_bytes,
             m.package_sha256, m.manifest_json
      FROM dictionary_active a
      JOIN dictionary_manifest m
        ON m.dictionary_id = a.dictionary_id AND m.revision = a.revision
      WHERE a.id = 1
    ''');
    return rows.isEmpty ? null : _resource(rows.first);
  }

  List<DictionaryResource> installed() {
    final rows = _db.select('''
      SELECT dictionary_id, revision, path, package_size_bytes,
             package_sha256, manifest_json
      FROM dictionary_manifest
      ORDER BY dictionary_id, revision
    ''');
    return [for (final row in rows) _resource(row)];
  }

  void activate(DictionaryResource resource) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        '''
        INSERT INTO dictionary_manifest (
          dictionary_id, revision, path, package_size_bytes, package_sha256,
          manifest_json, installed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(dictionary_id, revision) DO NOTHING
      ''',
        [
          resource.dictionaryId,
          resource.revision,
          resource.path,
          resource.sizeBytes,
          resource.sha256,
          resource.manifestJson,
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      final stored = _db
          .select(
            '''
        SELECT path, package_size_bytes, package_sha256
        FROM dictionary_manifest
        WHERE dictionary_id = ? AND revision = ?
      ''',
            [resource.dictionaryId, resource.revision],
          )
          .single;
      if (stored['path'] != resource.path ||
          stored['package_size_bytes'] != resource.sizeBytes ||
          stored['package_sha256'] != resource.sha256) {
        throw StateError(
          'immutable dictionary revision already has different content',
        );
      }
      _db.execute(
        '''
        INSERT INTO dictionary_active (id, dictionary_id, revision)
        VALUES (1, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          dictionary_id = excluded.dictionary_id,
          revision = excluded.revision
      ''',
        [resource.dictionaryId, resource.revision],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void deleteInstallation(String dictionaryId, int revision) {
    _db.execute(
      'DELETE FROM dictionary_manifest WHERE dictionary_id = ? AND revision = ?',
      [dictionaryId, revision],
    );
  }

  void removeInstallation(String dictionaryId, int revision) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        'DELETE FROM dictionary_active '
        'WHERE dictionary_id = ? AND revision = ?',
        [dictionaryId, revision],
      );
      _db.execute(
        'DELETE FROM dictionary_manifest '
        'WHERE dictionary_id = ? AND revision = ?',
        [dictionaryId, revision],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  DictionaryResource _resource(Row row) {
    final manifestJson = row['manifest_json'] as String;
    try {
      final manifest = DictionaryManifest.parse(jsonDecode(manifestJson));
      return manifest.toResource(
        path: row['path'] as String,
        packageSize: row['package_size_bytes'] as int,
        packageSha256: row['package_sha256'] as String,
        manifestJson: manifestJson,
      );
    } catch (_) {
      // Preserve only enough untrusted metadata to identify and remove an
      // incompatible installation during startup recovery.
      Map<String, Object?> map = const {};
      try {
        final metadata = jsonDecode(manifestJson);
        if (metadata is Map<String, Object?>) map = metadata;
      } catch (_) {
        // Invalid metadata remains incompatible. Recovery can still validate
        // its path from the trusted installation row.
      }
      return DictionaryResource(
        dictionaryId: row['dictionary_id'] as String,
        revision: row['revision'] as int,
        path: row['path'] as String,
        sizeBytes: row['package_size_bytes'] as int,
        sha256: row['package_sha256'] as String,
        databaseSizeBytes: row['package_size_bytes'] as int,
        databaseSha256: row['package_sha256'] as String,
        formatVersion: (map['format_version'] as String?) ?? 'legacy',
        schemaVersion: (map['schema_version'] as int?) ?? 0,
        displayName: (map['display_name'] as String?) ?? 'Dictionary',
        generatedAt: (map['generated_at'] as String?) ?? '',
        builderName: 'legacy',
        builderVersion: 'unknown',
        normalizationVersion: 'legacy',
        sources: const [],
        modifications: [
          if (map['modifications'] case final String value) value,
        ],
        manifestJson: manifestJson,
      );
    }
  }
}
