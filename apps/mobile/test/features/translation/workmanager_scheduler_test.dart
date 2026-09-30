import 'package:engirdle_mobile/features/translation/domain/translation_models.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/background_work.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/workmanager_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingEnqueuer implements OneOffWorkEnqueuer {
  final specs = <OneOffWorkSpec>[];
  final cancelled = <String>[];
  Object? enqueueError;

  @override
  Future<void> enqueue(OneOffWorkSpec spec) async {
    if (enqueueError != null) throw enqueueError!;
    specs.add(spec);
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    cancelled.add(uniqueName);
  }
}

void main() {
  TranslationJobConfig config({
    bool wifiOnly = false,
    bool chargingOnly = false,
  }) => TranslationJobConfig(
    provider: 'deepseek',
    origin: 'https://api.deepseek.com',
    model: 'deepseek-chat',
    promptVersion: 'translation-prompt@1',
    thinkingMode: 'off',
    reasoningEffort: 'none',
    timeoutSeconds: 120,
    maxRequestAttempts: 3,
    maxRetryRounds: 5,
    clientVersion: 'engirdle-mobile@1',
    wifiOnly: wifiOnly,
    chargingOnly: chargingOnly,
  );

  WorkManagerTranslationScheduler build(
    RecordingEnqueuer enqueuer, {
    TranslationJobConfig? Function(String jobId)? configOf,
  }) => WorkManagerTranslationScheduler(
    enqueuer: enqueuer,
    configOf: configOf ?? ((_) => config()),
    articleTitleOf: (jobId) => 'Job $jobId title',
  );

  test(
    'schedule maps to unique one-off work carrying the job id only',
    () async {
      final enqueuer = RecordingEnqueuer();
      build(enqueuer).schedule('job-1');
      await Future<void>.delayed(Duration.zero);

      expect(enqueuer.specs, hasLength(1));
      final spec = enqueuer.specs.single;
      expect(spec.uniqueName, translationWorkUniqueName('job-1'));
      expect(spec.taskName, kTranslationTaskName);
      // §9.2: WorkManager input data carries the job id and nothing else —
      // no article content, no config, no credentials.
      expect(spec.inputData.keys, [kTranslationJobInputKey]);
      expect(spec.inputData[kTranslationJobInputKey], 'job-1');
      expect(spec.initialDelay, Duration.zero);
      expect(spec.unmeteredOnly, isFalse);
      expect(spec.requiresCharging, isFalse);
      // The foreground notification is identified and titled per job.
      expect(spec.foregroundNotificationId, translationNotificationId('job-1'));
      expect(spec.foregroundNotificationTitle, contains('Job job-1 title'));
    },
  );

  test(
    'constraints come from the job config snapshot, not the live profile',
    () async {
      final enqueuer = RecordingEnqueuer();
      final scheduler = build(
        enqueuer,
        configOf: (jobId) => config(
          // job-1 was queued under 仅 Wi-Fi + 仅充电; job-2 was not.
          wifiOnly: jobId == 'job-1',
          chargingOnly: jobId == 'job-1',
        ),
      );

      scheduler.schedule('job-1');
      scheduler.schedule('job-2');
      await Future<void>.delayed(Duration.zero);

      // §8.4: a queued task's frozen constraints govern its execution —
      // editing the profile afterwards must not change them.
      expect(enqueuer.specs[0].unmeteredOnly, isTrue);
      expect(enqueuer.specs[0].requiresCharging, isTrue);
      expect(enqueuer.specs[1].unmeteredOnly, isFalse);
      expect(enqueuer.specs[1].requiresCharging, isFalse);
    },
  );

  test('a vanished job row schedules with connected-only defaults', () async {
    final enqueuer = RecordingEnqueuer();
    build(enqueuer, configOf: (_) => null).schedule('gone');
    await Future<void>.delayed(Duration.zero);
    expect(enqueuer.specs.single.unmeteredOnly, isFalse);
    expect(enqueuer.specs.single.requiresCharging, isFalse);
  });

  test('a transient-retry backoff becomes the work delay', () async {
    final enqueuer = RecordingEnqueuer();
    build(enqueuer).schedule('job-1', after: const Duration(seconds: 37));
    await Future<void>.delayed(Duration.zero);
    expect(enqueuer.specs.single.initialDelay, const Duration(seconds: 37));
  });

  test('cancelScheduled cancels the unique work name', () async {
    final enqueuer = RecordingEnqueuer();
    build(enqueuer).cancelScheduled('job-9');
    await Future<void>.delayed(Duration.zero);
    expect(enqueuer.cancelled, [translationWorkUniqueName('job-9')]);
  });

  test('enqueue failures never escape the unawaited call sites', () async {
    final enqueuer = RecordingEnqueuer()..enqueueError = StateError('no WM');
    final scheduler = build(enqueuer);
    // Neither throws: scheduling is best-effort, recover() repairs.
    scheduler.schedule('job-1');
    await Future<void>.delayed(Duration.zero);
    expect(enqueuer.specs, isEmpty);
  });
}
