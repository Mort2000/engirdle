import 'package:engirdle_mobile/features/translation/application/response_validation.dart';
import 'package:engirdle_mobile/features/translation/domain/translation_models.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/translation_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase db;
  late TranslationDao dao;

  setUp(() {
    db = AppDatabase.inMemory();
    addTearDown(db.close);
    dao = TranslationDao(db.db);
    db.db.execute(
      'INSERT INTO articles (article_id, title, revision, origin, '
      'current_artifact_revision, installed_at) VALUES '
      "('a1', 'Article', 1, 'paste', 1, '2026-01-01T00:00:00Z')",
    );
  });

  TranslationJobSnapshot queueJobAs(
    String jobId,
    String setId, {
    String articleId = 'a1',
  }) {
    dao.insertBuildingSet(
      translationSetId: setId,
      articleId: articleId,
      artifactRevision: 1,
      structureSha256: 'hash-1',
      targetLocale: 'zh-Hans',
      pipelineJson: '{}',
    );
    dao.insertJob(
      jobId: jobId,
      articleId: articleId,
      structureSha256: 'hash-1',
      targetLocale: 'zh-Hans',
      translationSetId: setId,
      config: _config,
      totalUnits: 2,
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    return dao.getJob(jobId)!;
  }

  TranslationJobSnapshot queueJob() => queueJobAs('job-1', 'set-1');

  void queueSecondJob() => queueJobAs('job-2', 'set-2', articleId: 'a2');

  test('profile upsert round-trips non-secret fields only', () {
    expect(dao.readProfile(), isNull);
    dao.saveProfile(
      LlmProfile(
        provider: 'deepseek',
        origin: 'https://api.deepseek.com',
        model: 'deepseek-chat',
        secretAlias: 'deepseek-key',
        wifiOnly: true,
        chargingOnly: false,
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    final profile = dao.readProfile()!;
    expect(profile.model, 'deepseek-chat');
    expect(profile.wifiOnly, isTrue);
    expect(profile.secretAlias, 'deepseek-key');
    // Only the alias lives in the row — never key material.
    final raw = db.db.select('SELECT * FROM llm_profiles').first;
    expect(raw.toString().contains('sk-'), isFalse);
    dao.saveProfile(profile.copyWith(model: 'deepseek-reasoner'));
    expect(dao.readProfile()!.model, 'deepseek-reasoner');
    expect(
      db.db.select('SELECT COUNT(*) AS n FROM llm_profiles').first['n'],
      1,
    );
  });

  test('claim moves queued jobs to running with a fresh generation', () {
    final job = queueJob();
    expect(job.status, TranslationJobStatus.queued);
    expect(job.completedUnits, 0);

    expect(dao.claim('job-1'), TranslationClaim.claimed);
    final running = dao.getJob('job-1')!;
    final generation = running.generation;
    expect(generation, 1);
    expect(running.status, TranslationJobStatus.running);
    expect(running.startedAt, isNotNull);
    expect(dao.holdsLease('job-1', generation), isTrue);
    expect(dao.holdsLease('job-1', generation - 1), isFalse);

    // A second claim of a running job is refused.
    expect(dao.claim('job-1'), TranslationClaim.unavailable);
    // Re-queue (retry/resume) issues a new generation on next claim.
    dao.requeue('job-1');
    expect(dao.claim('job-1'), TranslationClaim.claimed);
    expect(dao.getJob('job-1')!.generation, 2);
  });

  test('claim is exclusive: at most one running job at a time (§8.4)', () {
    queueJob();
    // A second ACTIVE job needs a different article (partial unique index:
    // one active job per article+locale).
    db.db.execute(
      'INSERT INTO articles (article_id, title, revision, origin, '
      'current_artifact_revision, installed_at) VALUES '
      "('a2', 'Second', 1, 'paste', 1, '2026-01-01T00:00:00Z')",
    );
    queueSecondJob();
    expect(dao.claim('job-1'), TranslationClaim.claimed);

    // The second job stays queued while the first executes; OS schedulers
    // may deliver both works at once, so this must be race-free in the DB.
    expect(dao.claim('job-2'), TranslationClaim.busy);
    expect(dao.getJob('job-2')!.status, TranslationJobStatus.queued);

    dao.updateStatus('job-1', TranslationJobStatus.completed);
    expect(dao.claim('job-2'), TranslationClaim.claimed);
  });

  test('claim refuses jobs whose building set is gone', () {
    queueJob();
    dao.deleteSet('set-1');
    expect(dao.claim('job-1'), TranslationClaim.unavailable);
  });

  test('acceptUnit journals, writes typed rows and derives progress', () {
    queueJob();
    dao.claim('job-1');
    final generation = dao.getJob('job-1')!.generation;
    dao.acceptUnit(
      jobId: 'job-1',
      generation: generation,
      unitOrder: 0,
      requestId: 'req-1',
      rawContent: '["译文一"]',
      translation: const SentenceUnitTranslation(
        blockId: 'block-1',
        translations: [(sentenceId: 's1', text: '译文一')],
      ),
    );
    var job = dao.getJob('job-1')!;
    expect(job.completedUnits, 1);
    expect(
      db.db
          .select(
            "SELECT text FROM sentence_translations WHERE sentence_id = 's1'",
          )
          .single['text'],
      '译文一',
    );
    dao.acceptUnit(
      jobId: 'job-1',
      generation: generation,
      unitOrder: 1,
      requestId: 'req-2',
      rawContent: '{}',
      translation: const TableUnitTranslation(
        blockId: 'block-2',
        cells: [(cellId: 'c1', text: '单元格'), (cellId: 'c2', text: '译文')],
      ),
    );
    job = dao.getJob('job-1')!;
    expect(job.completedUnits, 2);
    expect(
      db.db
          .select('SELECT COUNT(*) AS n FROM table_cell_translations')
          .first['n'],
      2,
    );
    // The journal is the accepted history: raw content in unit order.
    final journal = dao.acceptedUnits('job-1');
    expect(journal.map((u) => u.unitId), ['block-1', 'block-2']);
    expect(journal.first.content, '["译文一"]');

    // Duplicate unit orders are refused.
    expect(
      () => dao.acceptUnit(
        jobId: 'job-1',
        generation: generation,
        unitOrder: 0,
        requestId: 'req-3',
        rawContent: '["重复"]',
        translation: const SentenceUnitTranslation(
          blockId: 'block-1',
          translations: [(sentenceId: 's1', text: '重复')],
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('acceptUnit refuses writes from a stale lease', () {
    queueJob();
    dao.claim('job-1');
    final oldGeneration = dao.getJob('job-1')!.generation;
    dao.requeue('job-1');
    dao.claim('job-1');
    expect(dao.getJob('job-1')!.generation, oldGeneration + 1);
    expect(
      () => dao.acceptUnit(
        jobId: 'job-1',
        generation: oldGeneration,
        unitOrder: 0,
        requestId: 'req',
        rawContent: '["迟到"]',
        translation: const SentenceUnitTranslation(
          blockId: 'block-1',
          translations: [(sentenceId: 's1', text: '迟到')],
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(dao.getJob('job-1')!.completedUnits, 0);
  });

  test('cancelJob discards the building set and frees the slot', () {
    queueJob();
    dao.claim('job-1');
    final generation = dao.getJob('job-1')!.generation;
    dao.acceptUnit(
      jobId: 'job-1',
      generation: generation,
      unitOrder: 0,
      requestId: 'req',
      rawContent: '["译文"]',
      translation: const SentenceUnitTranslation(
        blockId: 'block-1',
        translations: [(sentenceId: 's1', text: '译文')],
      ),
    );
    dao.cancelJob('job-1');
    final job = dao.getJob('job-1')!;
    expect(job.status, TranslationJobStatus.cancelled);
    expect(job.translationSetId, isNull);
    expect(job.finishedAt, isNotNull);
    // Typed rows are gone with the set; the journal survives for audit.
    expect(
      db.db
          .select('SELECT COUNT(*) AS n FROM sentence_translations')
          .first['n'],
      0,
    );
    expect(dao.acceptedUnits('job-1'), hasLength(1));
    // Terminal jobs hold no slot: a fresh job may queue immediately.
    dao.insertBuildingSet(
      translationSetId: 'set-2',
      articleId: 'a1',
      artifactRevision: 1,
      structureSha256: 'hash-1',
      targetLocale: 'zh-Hans',
      pipelineJson: '{}',
    );
    dao.insertJob(
      jobId: 'job-2',
      articleId: 'a1',
      structureSha256: 'hash-1',
      targetLocale: 'zh-Hans',
      translationSetId: 'set-2',
      config: _config,
      totalUnits: 2,
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    expect(dao.getJob('job-2')!.status, TranslationJobStatus.queued);
  });

  test('activeJobs and latestJobForArticle queries', () {
    queueJob();
    final active = dao.activeJobs();
    expect(active.keys, ['a1']);
    expect(active['a1']!.status, TranslationJobStatus.queued);
    dao.updateStatus(
      'job-1',
      TranslationJobStatus.failed,
      errorKind: TranslationErrorKind.auth,
      errorDetail: 'provider rejected the API key',
    );
    expect(dao.activeJobs(), isEmpty);
    final failed = dao.getJob('job-1')!;
    expect(failed.errorKind, TranslationErrorKind.auth);
    expect(dao.latestJobForArticle('a1')!.jobId, 'job-1');
  });
}

const _config = TranslationJobConfig(
  provider: 'deepseek',
  origin: 'https://api.deepseek.com',
  model: 'deepseek-chat',
  promptVersion: 'full-article-sequential-units@v2',
  thinkingMode: 'enabled',
  reasoningEffort: 'max',
  timeoutSeconds: 120,
  maxRequestAttempts: 3,
  maxRetryRounds: 5,
  clientVersion: 'test',
);
