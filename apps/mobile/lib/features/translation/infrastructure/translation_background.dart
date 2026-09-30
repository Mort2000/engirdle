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

class NativeTranslationProgressReporter implements TranslationProgressReporter {
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
    TranslationProgressReporter reporter =
        const NativeTranslationProgressReporter(),
  }) async {
    final supportDir = await getApplicationSupportDirectory();
    final directories = AppDirectories(supportDir);
    await directories.ensureBaseLayout();
    final db = AppDatabase.open(directories.databaseFile.path);
    final dao = TranslationDao(db.db);
    final library = LibraryService(
      dao: LibraryDao(db.db),
      directories: directories,
      // Same table-ownership seam as the UI engine: packaged translation
      // rows install through the translation DAO inside the library's
      // transaction.
      packagedTranslationInstaller: dao.installPackagedSetFor,
    );
    final secrets = const KeystoreSecretStore();
    final client = DeepSeekMobileAdapter(secrets: secrets);
    final scheduler = WorkManagerTranslationScheduler(
      enqueuer: const WorkmanagerOneOffWorkEnqueuer(),
      // Job-constraints from the frozen config snapshot (§8.4), never the
      // live profile.
      configOf: (jobId) => dao.getJob(jobId)?.config,
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

  /// System-stop parking (§8.3/§9.3): an executor the OS interrupted never
  /// runs its own failure path, so the job row would linger in running with
  /// no waiting hint until WorkManager redelivers the stopped work (which
  /// only happens once the network constraint is satisfied again). Park
  /// every running job into waiting_retry — a system stop is a transport
  /// wait, not a model failure, so the retry budget is untouched — and post
  /// the waiting notification the stopped executor owed the user (§8.5/§9.2).
  /// The redelivered execution resumes from the journal via runJob's
  /// waiting_retry re-entry.
  Future<void> parkInterruptedOnSystemStop(String reason) async {
    final running = _dao
        .activeJobs()
        .values
        .where((job) => job.status == TranslationJobStatus.running)
        .toList();
    for (final job in running) {
      try {
        _dao.updateStatus(
          job.jobId,
          TranslationJobStatus.waitingRetry,
          errorKind: TranslationErrorKind.transport,
          errorDetail: '后台执行被系统中断（$reason），满足运行条件后自动继续',
        );
      } catch (_) {
        // Deleted or already terminal — nothing to park.
        continue;
      }
      final title = _library.getArticle(job.articleId)?.title ?? '文章';
      try {
        await _reporter.waiting(jobId: job.jobId, title: title);
      } catch (_) {
        // Notification failures never undo the park.
      }
    }
  }

  /// [parkInterruptedOnSystemStop] on a private session, for the dispatcher's
  /// onTaskStopped hook — best effort: the engine is about to be torn down,
  /// and a hard process kill skips this path entirely (recover() then
  /// re-drives the job on the next app start).
  static Future<void> parkInterruptedJobs(String reason) async {
    TranslationWorkerSession? session;
    try {
      session = await TranslationWorkerSession.open();
      await session.parkInterruptedOnSystemStop(reason);
    } catch (error) {
      _workerLogger.error('worker_stop_park_failed', {
        'reason': reason,
        'error': '$error',
      });
    } finally {
      try {
        await session?.close();
      } catch (_) {
        // The engine is being discarded either way.
      }
    }
  }

  /// Runs the job once and reports progress to the notification seam.
  /// Resolves `false` — WorkManager `Result.retry()`, redelivering THIS
  /// unique work after its backoff — for a §8.4 busy deferral (another job
  /// holds the single execution slot) and for a job parked in
  /// waiting_retry: the module's own re-enqueue under the keep policy is
  /// ignored while this work exists (§8.3's "耗尽后交给 WorkManager backoff"
  /// rides the OS retry, which also survives process death in the backoff
  /// window). Everything else resolves `true`: terminal outcomes and the
  /// module's retry-round accounting never touch WorkManager's.
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
      if (finalJob != null &&
          finalJob.status == TranslationJobStatus.waitingRetry) {
        return false;
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
      // The engine is about to be torn down (system stop, quota, constraint
      // change, cancel). Durability needs nothing here: every write is
      // already transactional under the job's lease, and WorkManager
      // redelivers the interrupted work (§8.4/§9.3). Visibility does: the
      // interrupted executor never runs its own failure path, so park its
      // running job into a visible waiting state (§8.5/§9.2).
      _workerLogger.info('worker_stopped', {
        'task': taskName,
        'reason': stopReason.name,
      });
      await TranslationWorkerSession.parkInterruptedJobs(stopReason.name);
    },
  );
}
