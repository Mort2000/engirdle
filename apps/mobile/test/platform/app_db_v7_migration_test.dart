import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/database/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// v6 → v7: mobile translation pipeline tables (lightweight-readpack design
/// §8/§11.1). Additive only; the partial unique index enforces the
/// one-active-job-per-article+locale invariant (§8.4) at the storage layer.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.inMemory();
    addTearDown(db.close);
  });

  void insertArticle(String articleId) => db.db.execute(
    'INSERT INTO articles (article_id, title, revision, origin, '
    'current_artifact_revision, installed_at) '
    "VALUES (?, ?, 1, 'paste', 1, '2026-01-01T00:00:00Z')",
    [articleId, articleId],
  );

  void insertJob(
    String jobId,
    String articleId,
    String status,
  ) => db.db.execute(
    'INSERT INTO translation_jobs (job_id, article_id, structure_sha256, '
    'target_locale, config_json, status, total_units, privacy_confirmed_at, '
    'created_at, updated_at) VALUES '
    "(?, ?, 'sh', 'zh-Hans', '{}', ?, 3, '2026-01-01T00:00:00Z', "
    "'2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
    [jobId, articleId, status],
  );

  test('fresh database migrates to v7 with the translation tables', () {
    expect(db.db.userVersion, kMigrations.length);
    final tables = {
      for (final row in db.db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ))
        row['name'] as String,
    };
    expect(tables, containsAll(['llm_profiles', 'translation_jobs',
      'translation_units']));
    final indexes = {
      for (final row in db.db.select(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      ))
        row['name'] as String,
    };
    expect(indexes, contains('idx_translation_jobs_one_active'));
  });

  test('only one active job per article and locale', () {
    insertArticle('a1');
    insertJob('j1', 'a1', 'queued');
    expect(
      () => insertJob('j2', 'a1', 'running'),
      throwsA(isA<SqliteException>()),
    );
    // A different locale may run in parallel.
    db.db.execute(
      'INSERT INTO translation_jobs (job_id, article_id, structure_sha256, '
      "target_locale, config_json, status, total_units, privacy_confirmed_at, "
      "created_at, updated_at) VALUES ('j3', 'a1', 'sh', 'ja', '{}', "
      "'queued', 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', "
      "'2026-01-01T00:00:00Z')",
    );
    // Terminal statuses free the slot: retry after failure re-queues.
    db.db.execute("UPDATE translation_jobs SET status = 'failed' "
        "WHERE job_id = 'j1'");
    insertJob('j2', 'a1', 'queued');
  });

  test('unit journal keys are unique per job and cascade with the article', () {
    insertArticle('a1');
    insertJob('j1', 'a1', 'running');
    void insertUnit(int order, String unitId) => db.db.execute(
      'INSERT INTO translation_units (job_id, unit_order, unit_id, '
      'unit_kind, accepted_content, completed_at) VALUES '
      "('j1', ?, ?, 'sentence', '[]', '2026-01-01T00:00:00Z')",
      [order, unitId],
    );
    insertUnit(0, 'block-1');
    // Same order or same unit id cannot be journaled twice.
    expect(
      () => insertUnit(0, 'block-2'),
      throwsA(isA<SqliteException>()),
    );
    expect(
      () => insertUnit(1, 'block-1'),
      throwsA(isA<SqliteException>()),
    );
    db.db.execute("DELETE FROM articles WHERE article_id = 'a1'");
    expect(
      db.db.select('SELECT COUNT(*) AS n FROM translation_jobs')
          .first['n'] as int,
      0,
    );
    expect(
      db.db.select('SELECT COUNT(*) AS n FROM translation_units')
          .first['n'] as int,
      0,
    );
  });
}
