/// Scheduler seam (design §7.3/§9.2): the module asks the runtime to run a
/// job; it never blocks queue() on execution. Adapters:
///  - [InProcessTranslationScheduler] (tests, foreground execution);
///  - WorkManager adapter (Android: unique one-off work with network /
///    charging constraints; delays are delegated to the OS scheduler so a
///    backoff timer survives process death, §8.3/§8.4).
///
/// The jobs table — not the scheduler — is the source of truth: executions
/// are idempotent (claim + lease guards in the module), so a lost, duplicated
/// or early request can never corrupt a job.
abstract interface class TranslationScheduler {
  /// Request an execution of [jobId]. [after] is the transient-retry backoff
  /// delay (§8.5); an adapter backed by a persistent scheduler may deliver
  /// the execution late (Doze, process restart) but must not need an
  /// in-process timer to deliver it at all.
  void schedule(String jobId, {Duration after});

  /// Drop not-yet-started executions of [jobId] (pause/cancel). An executor
  /// already running is stopped by the job's lease guard instead (§9.2).
  void cancelScheduled(String jobId);
}
