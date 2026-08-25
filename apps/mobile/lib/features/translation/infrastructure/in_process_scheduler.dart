import 'dart:async';
import 'dart:collection';

import '../application/translation_scheduler.dart';

/// Phase-3 scheduler: jobs run serially inside the app process. Global
/// serialization enforces "only one LLM job at a time" (design §8.4);
/// failures of one job never stop the queue.
///
/// The runner is bound after construction because the module and scheduler
/// reference each other (module schedules, scheduler executes module.runJob).
class InProcessTranslationScheduler implements TranslationScheduler {
  Future<void> Function(String jobId)? runner;

  final Queue<String> _pending = Queue();
  var _draining = false;

  @override
  void schedule(String jobId) {
    if (runner == null) return;
    _pending.add(jobId);
    unawaited(_drain());
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
