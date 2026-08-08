import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../domain/dictionary_models.dart';

/// DAO for the `dictionary_manifest` table in app.db (owned by the
/// dictionary feature). The dictionary SQLite itself is a separate,
/// versioned, read-only file — never coupled to app.db migrations.
class DictionaryManifestDao {
  const DictionaryManifestDao(this._db);

  final Database _db;

  DictionaryResource? current() {
    final rows = _db.select(
      'SELECT dictionary_id, revision, path, size_bytes, sha256, meta_json '
      'FROM dictionary_manifest ORDER BY installed_at DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final meta = jsonDecode(row['meta_json'] as String);
    final metaMap = meta is Map<String, Object?> ? meta : const <String, Object?>{};
    final sources = metaMap['sources'];
    return DictionaryResource(
      dictionaryId: row['dictionary_id'] as String,
      revision: row['revision'] as int,
      path: row['path'] as String,
      sizeBytes: row['size_bytes'] as int,
      sha256: row['sha256'] as String,
      displayName: (metaMap['display_name'] as String?) ?? 'Dictionary',
      sources: [
        if (sources is List) ...sources.whereType<String>(),
      ],
      modifications: metaMap['modifications'] as String?,
    );
  }

  void save(DictionaryResource resource) {
    _db.execute(
      'INSERT INTO dictionary_manifest (dictionary_id, revision, path, '
      'size_bytes, sha256, meta_json, installed_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(dictionary_id) DO UPDATE SET revision = excluded.revision, '
      'path = excluded.path, size_bytes = excluded.size_bytes, '
      'sha256 = excluded.sha256, meta_json = excluded.meta_json, '
      'installed_at = excluded.installed_at',
      [
        resource.dictionaryId,
        resource.revision,
        resource.path,
        resource.sizeBytes,
        resource.sha256,
        jsonEncode({
          'display_name': resource.displayName,
          'sources': resource.sources,
          'modifications': resource.modifications,
        }),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }
}
