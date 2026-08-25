import 'dart:async';
import 'dart:collection';

import '../application/translation_scheduler.dart';

/// Serial in-process scheduler: jobs run one at a time inside the app
/// process, enforcing "only one LLM job at a time" (design §8.4); failures
/// of one job never stop the queue. Backoff delays ([schedule] with
/// [Duration.after]) are plain timers, so they do not survive process death —
/// recovery re-drives those jobs on the next start.
///
/// The runner is bound after construction because the module and scheduler
/// reference each other (module schedules, scheduler executes module.runJob).
class InProcessTranslationScheduler implements TranslationScheduler {
  /// Runs one job; the result (e.g. a §8.4 busy deferral) is ignored here —
  /// the serial queue never hits it.
  Future<Object?> Function(String jobId)? runner;

  final Queue<String> _pending = Queue();
  // JobIds waiting out a backoff delay before entering the queue.
  final Set<String> _delayed = {};
  var _draining = false;

  @override
  void schedule(String jobId, {Duration after = Duration.zero}) {
    if (runner == null) return;
    if (after > Duration.zero) {
      // One timer per job: a second request while one is pending is a no-op
      // (the module schedules exactly one backoff per waiting_retry round).
      if (!_delayed.add(jobId)) return;
      unawaited(
        Future<void>.delayed(after, () {
          if (_delayed.remove(jobId) && runner != null) {
            _pending.add(jobId);
            unawaited(_drain());
          }
        }),
      );
      return;
    }
    _pending.add(jobId);
    unawaited(_drain());
  }

  @override
  void cancelScheduled(String jobId) {
    _delayed.remove(jobId);
    _pending.removeWhere((id) => id == jobId);
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final jobId = _pending.removeFirst();
        try {
          await runner!(jobId);
        } catch (_) {
          // Job-level failures are recorded in the jobs table by the module;
          // the scheduler only guarantees execution attempts.
        }
      }
    } finally {
      _draining = false;
    }
  }
}
