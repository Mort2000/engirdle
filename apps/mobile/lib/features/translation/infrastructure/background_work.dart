/// Names and ids shared by the scheduler adapter, the background dispatcher
/// and the Android notification plumbing (design §9.2). WorkManager input
/// data carries the job id ONLY — article content, config snapshots and
/// credentials always come from the app database and Keystore.
library;

/// Task name handed to the background dispatcher.
const String kTranslationTaskName = 'engirdle.translation.job';

/// Input-data key carrying the translation job id.
const String kTranslationJobInputKey = 'job_id';

/// Unique WorkManager name for one translation job: one pending execution
/// per job at any time (keep policy).
String translationWorkUniqueName(String jobId) => 'translation-job-$jobId';

/// Notification channel for the translation foreground service and result
/// notifications (§9.2: separate from the media playback channel).
const String kTranslationChannelId = 'engirdle_translation';
const String kTranslationChannelName = '文章翻译';

/// Stable notification id for a job's progress/foreground notification.
/// Computed with FNV-1a over UTF-8 so Dart and Kotlin derive the same id —
/// Dart's String.hashCode has no cross-platform stability guarantee.
/// (Waiting/result summaries use a separate id computed natively: they must
/// outlive the foreground service's notification.)
int translationNotificationId(String jobId) =>
    2000 + (_fnv1a(jobId) % 500000);

int _fnv1a(String value) {
  var hash = 0x811c9dc5;
  for (final byte in value.codeUnits) {
    // Job ids are UUIDs (ASCII); folding UTF-16 code units is equivalent to
    // UTF-8 bytes for this domain.
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}
