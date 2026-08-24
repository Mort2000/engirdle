import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Journal for raw-source imports (design §6.5): one row per import from the
/// moment staging is frozen until the install commits or the preview is
/// cancelled. The database is the source of truth for recovery — after
/// process death the confirmation page rebuilds from the staged canonical
/// text (deterministic re-parse guarded by the recorded hashes).
class SourceImportDao {
  const SourceImportDao(this._db);

  final Database _db;

  void insert(SourceImportRow row) {
    _db.execute(
      'INSERT INTO source_imports (import_id, state, syntax, raw_sha256, '
      'normalized_sha256, structure_sha256, suggested_title, stats_json, '
      'warnings_json, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        row.importId,
        row.state,
        row.syntax,
        row.rawSha256,
        row.normalizedSha256,
        row.structureSha256,
        row.suggestedTitle,
        row.statsJson,
        row.warningsJson,
        row.createdAt,
        row.updatedAt,
      ],
    );
  }

  void updateState(String importId, String state) {
    _db.execute(
      'UPDATE source_imports SET state = ?, updated_at = ? WHERE import_id = ?',
      [state, DateTime.now().toUtc().toIso8601String(), importId],
    );
  }

  void delete(String importId) {
    _db.execute('DELETE FROM source_imports WHERE import_id = ?', [importId]);
  }

  SourceImportRow? find(String importId) {
    final rows = _db.select(
      'SELECT * FROM source_imports WHERE import_id = ?',
      [importId],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  List<SourceImportRow> all() {
    final rows = _db.select('SELECT * FROM source_imports ORDER BY created_at');
    return [for (final row in rows) _fromRow(row)];
  }

  static SourceImportRow _fromRow(Row row) => SourceImportRow(
    importId: row['import_id'] as String,
    state: row['state'] as String,
    syntax: row['syntax'] as String,
    rawSha256: row['raw_sha256'] as String,
    normalizedSha256: row['normalized_sha256'] as String,
    structureSha256: row['structure_sha256'] as String,
    suggestedTitle: row['suggested_title'] as String,
    statsJson: row['stats_json'] as String,
    warningsJson: row['warnings_json'] as String,
    createdAt: row['created_at'] as String,
    updatedAt: row['updated_at'] as String,
  );
}

class SourceImportRow {
  const SourceImportRow({
    required this.importId,
    required this.state,
    required this.syntax,
    required this.rawSha256,
    required this.normalizedSha256,
    required this.structureSha256,
    required this.suggestedTitle,
    required this.statsJson,
    required this.warningsJson,
    required this.createdAt,
    required this.updatedAt,
  });

  final String importId;

  /// awaiting_confirmation | moving | committed | cancelled | failed.
  final String state;
  final String syntax;
  final String rawSha256;
  final String normalizedSha256;
  final String structureSha256;
  final String suggestedTitle;
  final String statsJson;
  final String warningsJson;
  final String createdAt;
  final String updatedAt;

  Map<String, Object?> get stats =>
      (jsonDecode(statsJson) as Map).cast<String, Object?>();
}
