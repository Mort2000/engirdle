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
  LlmProfile profile({bool wifiOnly = false, bool chargingOnly = false}) =>
      LlmProfile(
        provider: 'deepseek',
        origin: 'https://api.deepseek.com',
        model: 'deepseek-chat',
        secretAlias: 'deepseek-api-key',
        wifiOnly: wifiOnly,
        chargingOnly: chargingOnly,
        updatedAt: DateTime.utc(2026, 1, 1),
      );

  WorkManagerTranslationScheduler build(
    RecordingEnqueuer enqueuer, {
    LlmProfile? Function()? profileOf,
  }) => WorkManagerTranslationScheduler(
    enqueuer: enqueuer,
    profile: profileOf ?? (() => profile()),
    articleTitleOf: (jobId) => 'Job $jobId title',
  );

  test('schedule maps to unique one-off work carrying the job id only',
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
  });

  test('profile constraints apply at every schedule call', () async {
    final enqueuer = RecordingEnqueuer();
    var current = profile();
    final scheduler = build(enqueuer, profileOf: () => current);

    scheduler.schedule('job-1');
    current = profile(wifiOnly: true, chargingOnly: true);
    scheduler.schedule('job-2');
    await Future<void>.delayed(Duration.zero);

    expect(enqueuer.specs[0].unmeteredOnly, isFalse);
    expect(enqueuer.specs[0].requiresCharging, isFalse);
    expect(enqueuer.specs[1].unmeteredOnly, isTrue);
    expect(enqueuer.specs[1].requiresCharging, isTrue);
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
    expect(
      enqueuer.cancelled,
      [translationWorkUniqueName('job-9')],
    );
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
