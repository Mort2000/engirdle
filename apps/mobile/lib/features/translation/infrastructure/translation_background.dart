import 'dart:async';

import 'package:engirdle_native/engirdle_native.dart' as native;
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../../../platform/database/app_database.dart';
import '../../../platform/filesystem/app_directories.dart';
import '../../../platform/logging/app_logger.dart';
import '../../library/application/library_service.dart';
import '../../library/infrastructure/library_dao.dart';
import '../application/translation_module.dart';
import '../domain/translation_models.dart';
import 'background_work.dart';
import 'deepseek_adapter.dart';
import 'keystore_secret_store.dart';
import 'translation_dao.dart';
import 'workmanager_enqueue.dart';
import 'workmanager_scheduler.dart';

/// Progress / result notification seam for the worker (§12.4). Production
/// talks to the native plugin; tests script it.
abstract interface class TranslationProgressReporter {
  Future<void> progress({
    required String jobId,
    required String title,
    required int done,
    required int total,
  });

  Future<void> waiting({required String jobId, required String title});

  Future<void> finished({
    required String jobId,
    required String title,
    required bool succeeded,
  });

  /// Clears the job's notifications (pause/cancel/termination, §12.4).
  Future<void> dismiss({required String jobId});
}

class NativeTranslationProgressReporter
    implements TranslationProgressReporter {
  const NativeTranslationProgressReporter();

  @override
  Future<void> progress({
    required String jobId,
    required String title,
    required int done,
    required int total,
  }) => native.EngirdleTranslationNotifications.progress(
    jobId: jobId,
    title: title,
    done: done,
    total: total,
  );

  @override
  Future<void> waiting({required String jobId, required String title}) =>
      native.EngirdleTranslationNotifications.waiting(
        jobId: jobId,
        title: title,
      );

  @override
  Future<void> finished({
    required String jobId,
    required String title,
    required bool succeeded,
  }) => native.EngirdleTranslationNotifications.finished(
    jobId: jobId,
    title: title,
    succeeded: succeeded,
  );

  @override
  Future<void> dismiss({required String jobId}) =>
      native.EngirdleTranslationNotifications.dismiss(jobId: jobId);
}

/// The lean [TranslationWorkerDependencies] of design §9.2: its own SQLite
/// connection (WAL + busy timeout), the library projection, the translation
/// module, the secret store and the DeepSeek adapter — and nothing else. No
/// widgets, no AudioService, no player, no dictionary, no importer.
///
/// Everything durable is committed transactionally under the job's lease, so
/// the session may die at any instant: WorkManager redelivers, the next
/// session resumes from the journal (§8.4).
class TranslationWorkerSession {
  TranslationWorkerSession({
    required AppDatabase database,
    required LibraryService library,
    required TranslationDao dao,
    required TranslationModule translation,
    required TranslationProgressReporter reporter,
    AppLogger logger = const AppLogger('translation-worker'),
  }) : _database = database,
       _library = library,
       _dao = dao,
       _translation = translation,
       _reporter = reporter,
       _logger = logger;

  final AppDatabase _database;
  final LibraryService _library;
  final TranslationDao _dao;
  final TranslationModule _translation;
  final TranslationProgressReporter _reporter;
  final AppLogger _logger;

  /// Assembles the graph on the worker engine. Touches only plugin-backed
  /// platform services (path_provider and engirdle_native are registered on
  /// every engine; sqlite3 is FFI, engine-independent).
  static Future<TranslationWorkerSession> open({
    TranslationProgressReporter reporter = const NativeTranslationProgressReporter(),
  }) async {
    final supportDir = await getApplicationSupportDirectory();
    final directories = AppDirectories(supportDir);
    await directories.ensureBaseLayout();
    final db = AppDatabase.open(directories.databaseFile.path);
    final library = LibraryService(
      dao: LibraryDao(db.db),
      directories: directories,
    );
    final dao = TranslationDao(db.db);
    final secrets = const KeystoreSecretStore();
    final client = DeepSeekMobileAdapter(secrets: secrets);
    final scheduler = WorkManagerTranslationScheduler(
      enqueuer: const WorkmanagerOneOffWorkEnqueuer(),
      profile: dao.readProfile,
      articleTitleOf: (jobId) => _articleTitle(dao, library, jobId),
    );
    final translation = TranslationModule(
      dao: dao,
      library: library,
      client: client,
      secrets: secrets,
      scheduler: scheduler,
      // A worker-side terminal path (stale-source cancellation) must clear
      // the job's notifications too (§12.4).
      onJobTerminated: (jobId) {
        unawaited(reporter.dismiss(jobId: jobId));
      },
    );
    return TranslationWorkerSession(
      database: db,
      library: library,
      dao: dao,
      translation: translation,
      reporter: reporter,
    );
  }

  static String _articleTitle(
    TranslationDao dao,
    LibraryService library,
    String jobId,
  ) => translationArticleTitleOf(dao, library, jobId);

  /// The session's module — tests queue jobs through the real path.
  TranslationModule get translationForTest => _translation;

  /// Runs the job once and reports progress to the notification seam.
  /// Resolves `false` ONLY for a §8.4 busy deferral (another job holds the
  /// single execution slot) — WorkManager then retries this execution after
  /// its backoff. Everything else resolves `true`: retry rounds and backoff
  /// belong to the module and its persistent schedule, never to
  /// WorkManager's own retry accounting (§8.3).
  Future<bool> run(String jobId) async {
    final job = _dao.getJob(jobId);
    if (job == null) return true;
    final title = _library.getArticle(job.articleId)?.title ?? '文章';
    StreamSubscription<void>? events;
    try {
      events = _translation.changes.listen((_) {
        final snapshot = _dao.getJob(jobId);
        if (snapshot != null) {
          unawaited(_report(snapshot, title));
        }
      });
      final result = await _translation.runJob(jobId);
      final finalJob = _dao.getJob(jobId);
      // §12.4 distinguishes done/failed from cancel: a user cancel needs no
      // summary — it is deliberate, and its notifications are dismissed.
      if (finalJob != null && !finalJob.isActive) {
        if (finalJob.status == TranslationJobStatus.cancelled) {
          await _reporter.dismiss(jobId: jobId);
        } else {
          await _reporter.finished(
            jobId: jobId,
            title: title,
            succeeded: finalJob.status == TranslationJobStatus.completed,
          );
        }
      }
      return result != TranslationRunResult.deferredBusy;
    } catch (error) {
      _logger.error('worker_run_failed', {'job': jobId, 'error': '$error'});
      return true;
    } finally {
      await events?.cancel();
    }
  }

  Future<void> _report(TranslationJobSnapshot job, String title) async {
    try {
      switch (job.status) {
        case TranslationJobStatus.waitingRetry:
          await _reporter.waiting(jobId: job.jobId, title: title);
        case TranslationJobStatus.completed:
        case TranslationJobStatus.failed:
        case TranslationJobStatus.cancelled:
          await _reporter.finished(
            jobId: job.jobId,
            title: title,
            succeeded: job.status == TranslationJobStatus.completed,
          );
        case TranslationJobStatus.queued:
        case TranslationJobStatus.running:
        case TranslationJobStatus.paused:
          await _reporter.progress(
            jobId: job.jobId,
            title: title,
            done: job.completedUnits,
            total: job.totalUnits,
          );
      }
    } catch (error) {
      _logger.warn('report_failed', {'job': job.jobId, 'error': '$error'});
    }
  }

  Future<void> close() async {
    _translation.dispose();
    _library.dispose();
    _database.close();
  }
}

const AppLogger _workerLogger = AppLogger('translation-worker');

/// WorkManager callback dispatcher (design §9.2). Registered from main() on
/// the UI engine; the native side invokes it on a dedicated headless engine
/// for every translation work execution — including redelivery of
/// interrupted work after a process death.
///
/// The work input carries the job id ONLY (§9.2); article content, the
/// config snapshot and the API key are read from the app database and
/// Keystore by the session.
@pragma('vm:entry-point')
void translationCallbackDispatcher() {
  Workmanager().executeTask(
    (taskName, inputData) async {
      if (taskName != kTranslationTaskName) return true;
      final jobId = inputData?[kTranslationJobInputKey] as String?;
      if (jobId == null || jobId.isEmpty) {
        _workerLogger.error('worker_missing_job_id', {'task': taskName});
        return true;
      }
      TranslationWorkerSession? session;
      try {
        session = await TranslationWorkerSession.open();
        return await session.run(jobId);
      } catch (error) {
        _workerLogger.error('worker_session_failed', {
          'job': jobId,
          'error': '$error',
        });
        return true;
      } finally {
        try {
          await session?.close();
        } catch (_) {
          // The engine is being discarded either way.
        }
      }
    },
    onTaskStopped: (taskName, stopReason) async {
      // The engine is about to be torn down (system stop, quota, cancel).
      // Nothing needs persisting: every write is already transactional under
      // the job's lease, and WorkManager redelivers interrupted work — the
      // next executor takes over from the journal (§8.4/§9.3).
      _workerLogger.info('worker_stopped', {
        'task': taskName,
        'reason': stopReason.name,
      });
    },
  );
}
