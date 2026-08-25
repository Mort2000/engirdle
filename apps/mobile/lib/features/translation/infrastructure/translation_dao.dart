import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../application/response_validation.dart';
import '../domain/translation_models.dart';

/// DAO for translation-owned tables (design §11.1): llm_profiles,
/// translation_jobs and the translation_units journal. The building set rows
/// in the translation_sets family are written here too; the active pointer
/// (article_active_translations) is only ever switched through the library.
///
/// Progress is derived from the journal inside the same transaction that
/// accepts a unit, so the checkpoint can never lead or lag the verified
/// results (§8.4).
class TranslationDao {
  const TranslationDao(this._db);

  final Database _db;

  // ---- llm profile ----

  LlmProfile? readProfile() {
    final rows = _db.select('SELECT * FROM llm_profiles WHERE id = 1');
    if (rows.isEmpty) return null;
    final row = rows.first;
    return LlmProfile(
      provider: row['provider'] as String,
      origin: row['origin'] as String,
      model: row['model'] as String,
      secretAlias: row['secret_alias'] as String,
      wifiOnly: (row['wifi_only'] as int) == 1,
      chargingOnly: (row['charging_only'] as int) == 1,
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  void saveProfile(LlmProfile profile) {
    _db.execute(
      'INSERT INTO llm_profiles (id, provider, origin, model, secret_alias, '
      'wifi_only, charging_only, updated_at) VALUES (1, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET provider = excluded.provider, '
      'origin = excluded.origin, model = excluded.model, '
      'secret_alias = excluded.secret_alias, '
      'wifi_only = excluded.wifi_only, '
      'charging_only = excluded.charging_only, '
      'updated_at = excluded.updated_at',
      [
        profile.provider,
        profile.origin,
        profile.model,
        profile.secretAlias,
        profile.wifiOnly ? 1 : 0,
        profile.chargingOnly ? 1 : 0,
        _now(),
      ],
    );
  }

  // ---- building translation set ----

  /// Creates the job's building set. Partial rows under it are invisible to
  /// the reader until completion + activation.
  void insertBuildingSet({
    required String translationSetId,
    required String articleId,
    required int artifactRevision,
    required String structureSha256,
    required String targetLocale,
    required String pipelineJson,
  }) {
    _db.execute(
      'INSERT INTO translation_sets (translation_set_id, article_id, '
      'artifact_revision, structure_sha256, target_locale, origin, status, '
      'pipeline_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        translationSetId,
        articleId,
        artifactRevision,
        structureSha256,
        targetLocale,
        'mobile',
        'building',
        pipelineJson,
        _now(),
      ],
    );
  }

  /// Flips the building set to complete. Called only after the executor's
  /// exact-coverage verification; the authoritative re-check happens in the
  /// library's activation transaction.
  void completeSet(String translationSetId) {
    _db.execute(
      "UPDATE translation_sets SET status = 'complete' "
      'WHERE translation_set_id = ?',
      [translationSetId],
    );
    if (_db.updatedRows != 1) {
      throw StateError('completeSet: unknown set $translationSetId');
    }
  }

  /// Deletes a cancelled job's building set; its typed rows cascade and the
  /// job's translation_set_id becomes NULL (ON DELETE SET NULL).
  void deleteSet(String translationSetId) {
    _db.execute(
      'DELETE FROM translation_sets WHERE translation_set_id = ?',
      [translationSetId],
    );
  }

  // ---- jobs ----

  void insertJob({
    required String jobId,
    required String articleId,
    required String structureSha256,
    required String targetLocale,
    required String translationSetId,
    required TranslationJobConfig config,
    required int totalUnits,
    required DateTime privacyConfirmedAt,
  }) {
    final now = _now();
    _db.execute(
      'INSERT INTO translation_jobs (job_id, article_id, structure_sha256, '
      'target_locale, translation_set_id, config_json, status, generation, '
      'completed_units, total_units, retry_round, privacy_confirmed_at, '
      'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, 0, '
      '?, ?, ?)',
      [
        jobId,
        articleId,
        structureSha256,
        targetLocale,
        translationSetId,
        jsonEncode(config.toJson()),
        TranslationJobStatus.queued.wire,
        totalUnits,
        privacyConfirmedAt.toUtc().toIso8601String(),
        now,
        now,
      ],
    );
  }

  TranslationJobSnapshot? getJob(String jobId) {
    final rows = _db.select(
      'SELECT * FROM translation_jobs WHERE job_id = ?',
      [jobId],
    );
    if (rows.isEmpty) return null;
    return _snapshot(rows.first);
  }

  /// Active (slot-holding) jobs keyed by article id, for bookshelf badges.
  Map<String, TranslationJobSnapshot> activeJobs() {
    final rows = _db.select(
      "SELECT * FROM translation_jobs WHERE status IN "
      "('queued', 'running', 'waiting_retry', 'paused')",
    );
    return {for (final row in rows) row['article_id'] as String: _snapshot(row)};
  }

  /// Latest non-cancelled job of an article (any locale) for the task page.
  TranslationJobSnapshot? latestJobForArticle(String articleId) {
    final rows = _db.select(
      'SELECT * FROM translation_jobs WHERE article_id = ? '
      "AND status != 'cancelled' ORDER BY created_at DESC LIMIT 1",
      [articleId],
    );
    if (rows.isEmpty) return null;
    return _snapshot(rows.first);
  }

  /// Claims a queued job: status → running with a fresh generation token.
  /// Returns the new generation, or null when the job is no longer claimable
  /// (cancelled, already running, …). A queued job whose building set was
  /// removed cannot claim either — §8.4 recovery resumes from real rows.
  int? claim(String jobId) {
    final now = _now();
    _db.execute(
      "UPDATE translation_jobs SET status = 'running', "
      'generation = generation + 1, '
      'started_at = COALESCE(started_at, ?), updated_at = ? '
      "WHERE job_id = ? AND status = 'queued' AND translation_set_id "
      'IS NOT NULL',
      [now, now, jobId],
    );
    if (_db.updatedRows != 1) return null;
    return getJob(jobId)!.generation;
  }

  /// Guard for every unit write and post-response commit (§9.2): the worker
  /// may only write while it still holds the latest claim.
  bool holdsLease(String jobId, int generation) {
    final rows = _db.select(
      'SELECT status, generation FROM translation_jobs WHERE job_id = ?',
      [jobId],
    );
    if (rows.isEmpty) return false;
    final job = rows.first;
    return job['status'] == TranslationJobStatus.running.wire &&
        job['generation'] == generation;
  }

  /// Accepts one unit in a single transaction: the journal row, the typed
  /// translation rows under the building set, and the derived progress
  /// (§8.4 — checkpoint can never lead the results). Throws when the worker
  /// lost its lease or the journal already holds the unit.
  void acceptUnit({
    required String jobId,
    required int generation,
    required int unitOrder,
    required String requestId,
    required String rawContent,
    String? usageJson,
    required UnitTranslation translation,
  }) {
    final setRows = _db.select(
      'SELECT translation_set_id FROM translation_jobs WHERE job_id = ?',
      [jobId],
    );
    if (setRows.isEmpty || setRows.first['translation_set_id'] == null) {
      throw StateError('acceptUnit: job $jobId has no building set');
    }
    final setId = setRows.first['translation_set_id'] as String;
    _db.execute('BEGIN IMMEDIATE');
    try {
      if (!holdsLease(jobId, generation)) {
        throw StateError('acceptUnit: lease lost for job $jobId');
      }
      _db.execute(
        'INSERT INTO translation_units (job_id, unit_order, unit_id, '
        'unit_kind, accepted_content, request_id, usage_json, completed_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          jobId,
          unitOrder,
          translation.blockId,
          translation is TableUnitTranslation ? 'table' : 'sentence',
          rawContent,
          requestId,
          usageJson,
          _now(),
        ],
      );
      switch (translation) {
        case SentenceUnitTranslation():
          for (final item in translation.translations) {
            _db.execute(
              'INSERT INTO sentence_translations (translation_set_id, '
              'sentence_id, text) VALUES (?, ?, ?)',
              [setId, item.sentenceId, item.text],
            );
          }
        case TableUnitTranslation():
          for (final cell in translation.cells) {
            _db.execute(
              'INSERT INTO table_cell_translations (translation_set_id, '
              'block_id, cell_id, text) VALUES (?, ?, ?, ?)',
              [setId, translation.blockId, cell.cellId, cell.text],
            );
          }
      }
      _db.execute(
        'UPDATE translation_jobs SET completed_units = '
        '(SELECT COUNT(*) FROM translation_units WHERE job_id = ?), '
        'updated_at = ? WHERE job_id = ?',
        [jobId, _now(), jobId],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// The accepted journal in unit order — the assistant history source and
  /// the checkpoint truth for recovery.
  List<({int unitOrder, String unitId, String content})> acceptedUnits(
    String jobId,
  ) => [
    for (final row in _db.select(
      'SELECT unit_order, unit_id, accepted_content FROM translation_units '
      'WHERE job_id = ? ORDER BY unit_order',
      [jobId],
    ))
      (
        unitOrder: row['unit_order'] as int,
        unitId: row['unit_id'] as String,
        content: row['accepted_content'] as String,
      ),
  ];

  /// Sentence IDs translated under the set (exact-coverage verification).
  Set<String> sentenceTranslationIds(String translationSetId) => {
    for (final row in _db.select(
      'SELECT sentence_id FROM sentence_translations '
      'WHERE translation_set_id = ?',
      [translationSetId],
    ))
      row['sentence_id'] as String,
  };

  /// (blockId, cellId) pairs translated under the set.
  Set<(String, String)> tableCellTranslationIds(String translationSetId) => {
    for (final row in _db.select(
      'SELECT block_id, cell_id FROM table_cell_translations '
      'WHERE translation_set_id = ?',
      [translationSetId],
    ))
      (row['block_id'] as String, row['cell_id'] as String),
  };

  void updateStatus(
    String jobId,
    TranslationJobStatus status, {
    TranslationErrorKind? errorKind,
    String? errorDetail,
    int? retryRound,
  }) {
    _db.execute(
      'UPDATE translation_jobs SET status = ?, updated_at = ?, '
      'error_kind = ?, error_detail = ?, retry_round = COALESCE(?, '
      'retry_round), finished_at = CASE WHEN ? IN (?, ?) THEN ? ELSE '
      'finished_at END WHERE job_id = ? AND status NOT IN (?, ?)',
      [
        status.wire,
        _now(),
        errorKind?.wire,
        errorDetail,
        retryRound,
        status.wire,
        TranslationJobStatus.completed.wire,
        TranslationJobStatus.cancelled.wire,
        _now(),
        jobId,
        TranslationJobStatus.completed.wire,
        TranslationJobStatus.cancelled.wire,
      ],
    );
    if (_db.updatedRows != 1) {
      throw StateError('updateStatus: unknown job $jobId');
    }
  }

  /// Re-queues a paused/waiting/failed job for execution.
  void requeue(String jobId) =>
      updateStatus(jobId, TranslationJobStatus.queued);

  /// Cancels a job and discards its building set (partial results are never
  /// useful, §12.1). Idempotent from any non-terminal status.
  void cancelJob(String jobId) {
    final job = getJob(jobId);
    if (job == null || job.status.isTerminal) return;
    final setId = job.translationSetId;
    if (setId != null) deleteSet(setId);
    updateStatus(jobId, TranslationJobStatus.cancelled);
  }

  static TranslationJobSnapshot _snapshot(Row row) => TranslationJobSnapshot(
    jobId: row['job_id'] as String,
    articleId: row['article_id'] as String,
    structureSha256: row['structure_sha256'] as String,
    targetLocale: row['target_locale'] as String,
    translationSetId: row['translation_set_id'] as String?,
    status: TranslationJobStatus.fromName(row['status'] as String),
    generation: row['generation'] as int,
    completedUnits: row['completed_units'] as int,
    totalUnits: row['total_units'] as int,
    retryRound: row['retry_round'] as int,
    errorKind: TranslationErrorKind.fromName(row['error_kind'] as String?),
    errorDetail: row['error_detail'] as String?,
    config: TranslationJobConfig.fromJson(
      jsonDecode(row['config_json'] as String) as Map<String, Object?>,
    ),
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
    startedAt: _parseDate(row['started_at'] as String?),
    finishedAt: _parseDate(row['finished_at'] as String?),
  );

  static DateTime? _parseDate(String? value) =>
      value == null ? null : DateTime.parse(value);

  static String _now() => DateTime.now().toUtc().toIso8601String();
}
