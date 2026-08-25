/// Scheduler seam (design §7.3): the module asks the runtime to run a job;
/// it never blocks queue() on execution. Phase 3 runs jobs in-process
/// (serially — one LLM job at a time, §8.4); phase 4 replaces the adapter
/// with a WorkManager implementation carrying the same interface.
abstract interface class TranslationScheduler {
  void schedule(String jobId);
}
