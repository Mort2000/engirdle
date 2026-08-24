import 'package:sqlite3/sqlite3.dart';

import '../domain/import_models.dart';

/// DAO for the `import_operations` recovery log (owned by the importer).
class ImportLogDao {
  const ImportLogDao(this._db);

  final Database _db;

  static const _cols =
      'import_id, article_id, revision, artifact_revision, title, '
      'package_url, expected_size, expected_sha256, state, staging_path, '
      'error_kind, error_detail';

  void insert(ImportOperation op) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO import_operations ($_cols, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        op.importId,
        op.articleId,
        op.revision,
        op.artifactRevision,
        op.title,
        op.packageUrl,
        op.expectedSize,
        op.expectedSha256,
        op.state.name,
        op.stagingPath,
        op.errorKind,
        op.errorDetail,
        now,
        now,
      ],
    );
  }

  void updateState(
    String importId,
    ImportState state, {
    String? errorKind,
    String? errorDetail,
  }) {
    _db.execute(
      'UPDATE import_operations SET state = ?, error_kind = ?, '
      'error_detail = ?, updated_at = ? WHERE import_id = ?',
      [
        state.name,
        errorKind,
        errorDetail,
        DateTime.now().toUtc().toIso8601String(),
        importId,
      ],
    );
  }

  void delete(String importId) {
    _db.execute('DELETE FROM import_operations WHERE import_id = ?', [
      importId,
    ]);
  }

  /// All logged operations in insertion order (recovery replays or rolls
  /// back each state). Rows with an unknown state are skipped — one
  /// corrupt or newer-version row must not block the others.
  List<ImportOperation> unfinished() {
    final rows = _db.select(
      'SELECT $_cols FROM import_operations ORDER BY created_at, rowid',
    );
    return [for (final row in rows) ?_fromRow(row)];
  }

  ImportOperation? byId(String importId) {
    final rows = _db.select(
      'SELECT $_cols FROM import_operations WHERE import_id = ?',
      [importId],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  static ImportOperation? _fromRow(Row row) {
    final state = ImportState.fromName(row['state'] as String);
    if (state == null) return null;
    return ImportOperation(
      importId: row['import_id'] as String,
      articleId: row['article_id'] as String,
      revision: row['revision'] as int,
      artifactRevision: row['artifact_revision'] as int,
      title: row['title'] as String,
      packageUrl: row['package_url'] as String,
      expectedSize: row['expected_size'] as int,
      expectedSha256: row['expected_sha256'] as String,
      state: state,
      stagingPath: row['staging_path'] as String,
      errorKind: row['error_kind'] as String?,
      errorDetail: row['error_detail'] as String?,
    );
  }
}
