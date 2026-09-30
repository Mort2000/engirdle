import '../../../platform/logging/app_logger.dart';
import '../../library/application/library_service.dart';
import '../application/translation_scheduler.dart';
import '../domain/translation_models.dart';
import 'background_work.dart';
import 'translation_dao.dart';

/// Platform-neutral description of one persistent background execution,
/// mapped by the enqueuer to the host scheduler (WorkManager on Android).
class OneOffWorkSpec {
  const OneOffWorkSpec({
    required this.uniqueName,
    required this.taskName,
    required this.inputData,
    this.initialDelay = Duration.zero,
    this.unmeteredOnly = false,
    this.requiresCharging = false,
    this.foregroundNotificationId,
    this.foregroundNotificationTitle,
  });

  final String uniqueName;
  final String taskName;
  final Map<String, Object?> inputData;
  final Duration initialDelay;
  final bool unmeteredOnly;
  final bool requiresCharging;
  final int? foregroundNotificationId;
  final String? foregroundNotificationTitle;
}

/// Shared job → article-title lookup for the enqueue-time foreground
/// notification (both engines construct the scheduler with it).
String translationArticleTitleOf(
  TranslationDao dao,
  LibraryService library,
  String jobId,
) {
  final job = dao.getJob(jobId);
  if (job == null) return '文章';
  return library.getArticle(job.articleId)?.title ?? '文章';
}

/// Seam between the scheduler adapter and the host background scheduler.
/// Production wraps the workmanager plugin; tests record requests.
abstract interface class OneOffWorkEnqueuer {
  Future<void> enqueue(OneOffWorkSpec spec);

  Future<void> cancelByUniqueName(String uniqueName);
}

/// [TranslationScheduler] backed by persistent one-off work (§9.2):
///
/// - one unique name per job — re-registration under a keep policy never
///   duplicates a pending or running execution, whatever called it;
/// - constraints (connected always; unmetered / charging) are resolved from
///   the job's frozen config snapshot at every schedule call (§8.4) —
///   profile edits after queue never change a queued task's conditions;
/// - transient-retry backoff becomes the work's initial delay, so the
///   window survives process death (§8.3) — no in-process timer is involved;
/// - the module's lease guards remain the authority for anything already
///   executing; [cancelScheduled] only drops not-yet-started work.
class WorkManagerTranslationScheduler implements TranslationScheduler {
  WorkManagerTranslationScheduler({
    required OneOffWorkEnqueuer enqueuer,
    required TranslationJobConfig? Function(String jobId) configOf,
    required String Function(String jobId) articleTitleOf,
    AppLogger logger = const AppLogger('translation-scheduler'),
  }) : _enqueuer = enqueuer,
       _configOf = configOf,
       _articleTitleOf = articleTitleOf,
       _logger = logger;

  final OneOffWorkEnqueuer _enqueuer;
  final TranslationJobConfig? Function(String jobId) _configOf;
  final String Function(String jobId) _articleTitleOf;
  final AppLogger _logger;

  @override
  void schedule(String jobId, {Duration after = Duration.zero}) {
    final config = _configOf(jobId);
    // A network connection is always required (§9.2) — translation without
    // connectivity can never make progress. A vanished job row schedules
    // nothing special: connected-only is the least surprising default and
    // the execution itself is a no-op.
    final spec = OneOffWorkSpec(
      uniqueName: translationWorkUniqueName(jobId),
      taskName: kTranslationTaskName,
      inputData: {kTranslationJobInputKey: jobId},
      initialDelay: after,
      unmeteredOnly: config?.wifiOnly ?? false,
      requiresCharging: config?.chargingOnly ?? false,
      foregroundNotificationId: translationNotificationId(jobId),
      foregroundNotificationTitle: '正在翻译：${_articleTitleOf(jobId)}',
    );
    _enqueuer.enqueue(spec).catchError((Object error) {
      // Scheduling is best-effort: recover() re-drives unscheduled active
      // jobs on the next app start, and a lost retry delivery is repaired
      // the same way. Never crash an unawaited call site.
      _logger.error('enqueue_failed', {
        'job': jobId,
        'delay_ms': after.inMilliseconds,
        'error': '$error',
      });
    });
  }

  @override
  void cancelScheduled(String jobId) {
    _enqueuer.cancelByUniqueName(translationWorkUniqueName(jobId)).catchError((
      Object error,
    ) {
      _logger.error('cancel_failed', {'job': jobId, 'error': '$error'});
    });
  }
}
