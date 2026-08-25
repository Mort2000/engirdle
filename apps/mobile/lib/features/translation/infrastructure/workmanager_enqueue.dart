import 'package:workmanager/workmanager.dart';

import 'background_work.dart';
import 'workmanager_scheduler.dart';

/// [OneOffWorkEnqueuer] on top of the workmanager plugin (declarative
/// mapping — the adapter logic lives in [WorkManagerTranslationScheduler]
/// and is tested against a recording enqueuer instead).
///
/// The work runs as a `dataSync` foreground service for its whole duration
/// (§9.2): the notification channel is the dedicated translation channel,
/// never the media playback one. The plugin shows the notification from
/// registration-time config; once the worker starts it re-posts the same
/// notification id with live progress (§9.2/§12.4).
class WorkmanagerOneOffWorkEnqueuer implements OneOffWorkEnqueuer {
  const WorkmanagerOneOffWorkEnqueuer();

  @override
  Future<void> enqueue(OneOffWorkSpec spec) {
    return Workmanager().registerOneOffTask(
      spec.uniqueName,
      spec.taskName,
      inputData: spec.inputData,
      initialDelay: spec.initialDelay <= Duration.zero
          ? null
          : spec.initialDelay,
      constraints: Constraints(
        // A connection is always required (§9.2); the profile only decides
        // whether it must be unmetered.
        networkType: spec.unmeteredOnly
            ? NetworkType.unmetered
            : NetworkType.connected,
        requiresCharging: spec.requiresCharging ? true : null,
      ),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      // Only the §8.4 busy deferral returns failure from the worker; the
      // backoff here paces those retries.
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
      foregroundServiceConfig: ForegroundServiceConfig(
        notificationChannelId: kTranslationChannelId,
        notificationChannelName: kTranslationChannelName,
        notificationTitle: spec.foregroundNotificationTitle,
        notificationText: '翻译将在后台继续，完成后会通知你。',
        notificationId: spec.foregroundNotificationId,
        foregroundServiceType: ForegroundServiceType.dataSync,
      ),
    );
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) {
    return Workmanager().cancelByUniqueName(uniqueName);
  }
}
