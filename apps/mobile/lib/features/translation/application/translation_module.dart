import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../../shared_kernel/id_generator.dart';
import '../../library/application/library_service.dart';
import '../../library/domain/installed_article.dart';
import '../domain/translation_errors.dart';
import '../domain/translation_models.dart';
import '../infrastructure/deepseek_adapter.dart';
import '../infrastructure/translation_dao.dart';
import 'llm_client.dart';
import 'response_validation.dart';
import 'secret_store.dart';
import 'translation_plan.dart';
import 'translation_protocol.dart';
import 'translation_scheduler.dart';

/// Client version frozen into every job's config snapshot (§8.4).
const String kTranslationClientVersion = 'engirdle-mobile@1';

/// Conservative model context window (tokens; kept at the smallest window
/// any supported DeepSeek model is documented to serve). The queue precheck
/// refuses articles whose FIRST request alone would eat more than half the
/// window — history replay only grows from there (§8.6).
const int kContextWindowTokens = 65536;
const int kContextReserveTokens = kContextWindowTokens ~/ 2;

/// Queue-time refusal with an actionable category (§8.5); presentation maps
/// the kind to user guidance without technical detail.
class TranslationQueueRefusal implements Exception {
  const TranslationQueueRefusal(this.kind, this.message);

  final TranslationErrorKind kind;
  final String message;

  @override
  String toString() => 'TranslationQueueRefusal(${kind.name}: $message)';
}

/// Outcome of one execution attempt (runJob).
enum TranslationRunResult {
  /// The attempt ran (possibly to a parked/terminal state).
  ran,

  /// Nothing was claimable to run (wrong state, vanished job, …).
  notRunnable,

  /// §8.4: another job is executing. The job stays queued; the caller's
  /// scheduler should retry this execution later.
  deferredBusy,
}

/// Raised by the module's internal backoff sleep when the execution lease
/// drops mid-wait: the retry loop must stop silently — the job was
/// cancelled, paused or superseded, and no further request may leave the
/// device (§9.2).
class _LeaseLostDuringBackoff implements Exception {
  const _LeaseLostDuringBackoff();
}

/// The mobile translation deep module (design §7.2/§8): queue, cancel,
/// pause/resume, retry and watch. Everything else — plan derivation, prompt
/// projection, placeholder protection, checkpoint journal, bounded retries,
/// atomic activation and recovery — is hidden behind this interface.
///
/// The jobs table is the source of truth; the scheduler only triggers
/// execution. Correctness never depends on a continuous run: every accepted
/// unit is durable, and [recover] re-drives interrupted jobs.
class TranslationModule {
  TranslationModule({
    required TranslationDao dao,
    required LibraryService library,
    required LlmCompletionClient client,
    required TranslationSecretStore secrets,
    required TranslationScheduler scheduler,
    Future<void> Function(Duration)? sleeper,
    Duration Function(int retryRound)? backoffFor,
    void Function(String jobId)? onJobTerminated,
  }) : _dao = dao,
       _library = library,
       _client = client,
       _secrets = secrets,
       _scheduler = scheduler,
       _sleeper = sleeper ?? Future<void>.delayed,
       _backoffFor = backoffFor ?? _defaultBackoff,
       _onJobTerminated = onJobTerminated;

  final TranslationDao _dao;
  final LibraryService _library;
  final LlmCompletionClient _client;
  final TranslationSecretStore _secrets;
  final TranslationScheduler _scheduler;
  final Future<void> Function(Duration) _sleeper;
  final Duration Function(int retryRound) _backoffFor;

  /// Fired whenever a job leaves the active set through cancel, pause or
  /// stale-source cancellation — composition roots use it to clear the
  /// job's notifications (§12.4). Not fired for completion/failure: the
  /// worker posts those summaries itself.
  final void Function(String jobId)? _onJobTerminated;

  // Sync delivery: notify() fires listeners immediately (never during a DB
  // transaction — every call site commits first). The background worker's
  // progress notifications ride this stream; an async controller would only
  // deliver after the run finishes.
  final StreamController<void> _changes = StreamController.broadcast(
    sync: true,
  );

  /// Notifies on every job change (bookshelf badges, reader status bar).
  Stream<void> get changes => _changes.stream;

  /// Live snapshots of one job; emits the current state immediately.
  Stream<TranslationJobSnapshot> watch(String jobId) {
    late StreamController<TranslationJobSnapshot> controller;
    controller = StreamController.broadcast(
      onListen: () {
        final job = _dao.getJob(jobId);
        if (job != null) controller.add(job);
      },
    );
    late final StreamSubscription<void> sub;
    sub = changes.listen((_) {
      final job = _dao.getJob(jobId);
      if (job != null) controller.add(job);
    });
    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  Map<String, TranslationJobSnapshot> activeJobs() => _dao.activeJobs();

  TranslationJobSnapshot? latestJobForArticle(String articleId) =>
      _dao.latestJobForArticle(articleId);

  TranslationJobSnapshot? jobById(String jobId) => _dao.getJob(jobId);

  /// Conservative cost/context estimate for the confirmation page (§8.6).
  /// Token numbers are estimates only, never a fee promise.
  TranslationEstimate estimate(String articleId) {
    final content = _library.getContent(articleId);
    if (content == null) {
      throw const TranslationQueueRefusal(
        TranslationErrorKind.staleSource,
        '文章不存在或已变更，请重新打开后再试。',
      );
    }
    final plan = buildTranslationPlan(content.blocks);
    final context = buildSourceContext(
      title: content.article.title,
      author: content.article.author,
      blocks: content.blocks,
    );
    final contextChars = kTranslationSystemPrompt.length + context.length;
    final requestChars = [
      for (final unit in plan.units) buildUnitRequest(unit).length,
    ];
    // Full-replay growth: request i replays system+context plus every
    // earlier request and its (assumed same-length) reply.
    var totalChars = 0;
    var firstRequestChars = contextChars;
    for (var i = 0; i < requestChars.length; i++) {
      totalChars += contextChars + requestChars[i];
      for (var j = 0; j < i; j++) {
        totalChars += 2 * requestChars[j];
      }
      if (i == 0) firstRequestChars += requestChars.first;
    }
    final sentenceCount = content.sentences.length;
    final tableCount = content.blocks.whereType<InstalledTableBlock>().length;
    final firstRequestTokens = firstRequestChars ~/ 3;
    return TranslationEstimate(
      articleChars: context.length,
      sentenceCount: sentenceCount,
      tableCount: tableCount,
      unitCount: plan.units.length,
      minInputTokens: totalChars ~/ 4,
      maxInputTokens: totalChars ~/ 2,
      contextTooLarge: firstRequestTokens > kContextReserveTokens,
    );
  }

  /// Validates the request, freezes the job config snapshot, creates the
  /// building translation set and schedules execution (§8.2).
  Future<TranslationJobSnapshot> queueTranslation({
    required String articleId,
    required DateTime privacyConfirmedAt,
  }) async {
    final article = _library.getArticle(articleId);
    if (article == null) {
      throw const TranslationQueueRefusal(
        TranslationErrorKind.staleSource,
        '文章不存在或已变更，请重新打开后再试。',
      );
    }
    if (article.structureSha256 == null) {
      // Pre-v5 installs never stored one; derivatives must bind the exact
      // hash (§4.1), so those articles need a re-import first.
      throw const TranslationQueueRefusal(
        TranslationErrorKind.config,
        '此文章为旧版本安装、缺少结构哈希；重新导入后才能翻译。',
      );
    }
    if (_dao.activeJobs().containsKey(articleId)) {
      throw const TranslationQueueRefusal(
        TranslationErrorKind.config,
        '这篇文章已有正在进行的翻译任务。',
      );
    }
    final estimate = this.estimate(articleId);
    final content = _library.getContent(articleId)!;
    final plan = buildTranslationPlan(content.blocks);
    if (!plan.canTranslate) {
      throw const TranslationQueueRefusal(
        TranslationErrorKind.config,
        '这篇文章没有可翻译的正文。',
      );
    }
    if (estimate.contextTooLarge) {
      throw const TranslationQueueRefusal(
        TranslationErrorKind.contextLimit,
        '文章（含翻译历史回放）预计超出模型上下文上限，暂不开始翻译。',
      );
    }
    final profile = _dao.readProfile();
    if (profile == null || profile.provider != kDeepSeekProvider) {
      throw const TranslationQueueRefusal(
        TranslationErrorKind.config,
        '尚未配置翻译服务；请先到 设置 › 翻译服务 完成配置。',
      );
    }
    if (profile.origin != kDeepSeekOfficialOrigin) {
      throw const TranslationQueueRefusal(
        TranslationErrorKind.config,
        '翻译服务端点配置异常，请到 设置 › 翻译服务 重新保存。',
      );
    }
    final secret = await _secrets.read(profile.secretAlias);
    if (secret == null || secret.trim().isEmpty) {
      throw const TranslationQueueRefusal(
        TranslationErrorKind.auth,
        '尚未保存 DeepSeek API Key；请先到 设置 › 翻译服务 填写。',
      );
    }

    final jobId = newUuid();
    final setId = newUuid();
    _dao.insertBuildingSet(
      translationSetId: setId,
      articleId: articleId,
      artifactRevision: article.artifactRevision,
      structureSha256: article.structureSha256!,
      targetLocale: kTranslationTargetLocale,
      pipelineJson: _pipelineJson(profile.model),
    );
    final config = TranslationJobConfig(
      provider: profile.provider,
      origin: profile.origin,
      model: profile.model,
      promptVersion: kTranslationPromptVersion,
      thinkingMode: kTranslationThinkingMode,
      reasoningEffort: kTranslationReasoningEffort,
      timeoutSeconds: 120,
      maxRequestAttempts: 3,
      maxRetryRounds: 5,
      clientVersion: kTranslationClientVersion,
      // Constraints freeze with the rest of the snapshot (§8.4/§9.2): the
      // scheduler reads them from the job row, so later profile edits never
      // change a queued task's execution conditions.
      wifiOnly: profile.wifiOnly,
      chargingOnly: profile.chargingOnly,
    );
    _dao.insertJob(
      jobId: jobId,
      articleId: articleId,
      structureSha256: article.structureSha256!,
      targetLocale: kTranslationTargetLocale,
      translationSetId: setId,
      config: config,
      totalUnits: plan.units.length,
      privacyConfirmedAt: privacyConfirmedAt,
    );
    _notify();
    _scheduler.schedule(jobId);
    return _dao.getJob(jobId)!;
  }

  /// User cancel from any non-terminal state: the building set is discarded
  /// and an in-flight worker's next write fails the lease guard.
  void cancel(String jobId) {
    _dao.cancelJob(jobId);
    _scheduler.cancelScheduled(jobId);
    _onJobTerminated?.call(jobId);
    _notify();
  }

  void pause(String jobId) {
    final job = _dao.getJob(jobId);
    if (job == null || !job.isActive) return;
    _dao.updateStatus(jobId, TranslationJobStatus.paused);
    // Pending executions (including a not-yet-fired backoff delivery) are
    // dropped; an executor already running is stopped by the lease guard.
    _scheduler.cancelScheduled(jobId);
    _onJobTerminated?.call(jobId);
    _notify();
  }

  void resume(String jobId) {
    final job = _dao.getJob(jobId);
    if (job == null || job.status != TranslationJobStatus.paused) return;
    _dao.requeue(jobId);
    _notify();
    _scheduler.schedule(jobId);
  }

  /// Same-configuration retry of a failed job: resumes from the journal
  /// checkpoint, it never retranslates accepted units (§8.3).
  void retry(String jobId) {
    final job = _dao.getJob(jobId);
    if (job == null || job.status != TranslationJobStatus.failed) return;
    _dao.requeue(jobId);
    _notify();
    _scheduler.schedule(jobId);
  }

  /// Startup reconciliation (§8.4): a job found running/waiting after a
  /// process death resumes from its journal; paused jobs stay paused (§8.3 —
  /// only the user resumes them); jobs whose source drifted or whose
  /// building set vanished are cancelled and never activated.
  ///
  /// A running job is never re-queued here: its executor may still be alive
  /// (the UI opened mid-run), and if it died the OS scheduler redelivers the
  /// interrupted work — [runJob] takes over from either path. The
  /// keep-policy schedule merely guarantees that some execution is pending.
  Future<void> recover() async {
    for (final job in _dao.activeJobs().values) {
      if (job.status == TranslationJobStatus.paused) continue;
      final article = _library.getArticle(job.articleId);
      if (article == null ||
          article.structureSha256 != job.structureSha256 ||
          job.translationSetId == null) {
        _dao.cancelJob(job.jobId);
        _notify();
        continue;
      }
      if (job.status != TranslationJobStatus.running) {
        _dao.requeue(job.jobId);
        _notify();
      }
      _scheduler.schedule(job.jobId);
    }
  }

  // ---- execution ----

  /// One execution attempt: claim → replay history from the journal →
  /// translate pending units → verify coverage → activate atomically.
  /// Invoked by the scheduler; safe to call repeatedly (idempotent guards).
  Future<TranslationRunResult> runJob(String jobId) async {
    var job = _dao.getJob(jobId);
    if (job == null) return TranslationRunResult.notRunnable;
    // Scheduler re-entry (§8.3/§9.2): a waiting_retry job is only re-invoked
    // by its backoff delivery, and a running job only by the OS scheduler
    // redelivering interrupted work — the previous executor is gone by then
    // (unique work never runs two executors at once), so re-queue and take
    // over from the journal. Every other non-queued state (paused, terminal)
    // is left untouched.
    if (job.status == TranslationJobStatus.waitingRetry ||
        job.status == TranslationJobStatus.running) {
      _dao.requeue(jobId);
      job = _dao.getJob(jobId)!;
    }
    if (job.status != TranslationJobStatus.queued) {
      return TranslationRunResult.notRunnable;
    }

    final article = _library.getArticle(job.articleId);
    if (article == null || article.structureSha256 != job.structureSha256) {
      await _cancelStale(job, 'the article source changed');
      return TranslationRunResult.ran;
    }
    final content = _library.getContent(job.articleId);
    if (content == null) {
      await _cancelStale(job, 'the article is no longer readable');
      return TranslationRunResult.ran;
    }
    final plan = buildTranslationPlan(content.blocks);
    if (plan.units.length != job.totalUnits) {
      await _cancelStale(job, 'the article structure changed');
      return TranslationRunResult.ran;
    }

    switch (_dao.claim(jobId)) {
      case TranslationClaim.busy:
        // §8.4: another job holds the single execution slot. Leave the job
        // queued — the host scheduler retries this execution.
        return TranslationRunResult.deferredBusy;
      case TranslationClaim.unavailable:
        return TranslationRunResult.notRunnable;
      case TranslationClaim.claimed:
        break;
    }
    final generation = _dao.getJob(jobId)!.generation;
    job = _dao.getJob(jobId)!;
    final config = job.config;

    final journal = _dao.acceptedUnits(jobId);
    // Reconciliation: the journal must be a prefix of the current plan.
    for (var i = 0; i < journal.length; i++) {
      if (journal[i].unitId != plan.units[i].blockId) {
        await _cancelStale(
          job,
          'the accepted journal does not match the '
          'article structure',
        );
        return TranslationRunResult.ran;
      }
    }

    try {
      await _translatePendingUnits(
        jobId: jobId,
        generation: generation,
        config: config,
        content: content,
        plan: plan,
        journal: journal,
      );
      await _finalize(jobId: jobId, generation: generation, plan: plan);
    } on LlmException catch (error) {
      await _onUnitFailure(jobId, _toErrorKind(error.kind), error.message);
    } on TranslationProtocolError catch (error) {
      await _onUnitFailure(jobId, TranslationErrorKind.protocol, error.message);
    } on StateError catch (error) {
      await _onUnitFailure(jobId, TranslationErrorKind.config, error.message);
    } catch (error) {
      // Fallback for unclassified client errors: without it the job would
      // stay running forever while the host scheduler reports success —
      // a dead task no redelivery can repair (nothing re-invokes it).
      try {
        await _onUnitFailure(
          jobId,
          TranslationErrorKind.internal,
          'unexpected error: $error',
        );
      } catch (_) {
        // The DB write itself failed; nothing more this executor can do.
      }
    }
    return TranslationRunResult.ran;
  }

  Future<void> _translatePendingUnits({
    required String jobId,
    required int generation,
    required TranslationJobConfig config,
    required InstalledContent content,
    required TranslationPlan plan,
    required List<({int unitOrder, String unitId, String content})> journal,
  }) async {
    final sourceContext = buildSourceContext(
      title: content.article.title,
      author: content.article.author,
      blocks: content.blocks,
    );
    for (var i = journal.length; i < plan.units.length; i++) {
      // Lease guard before every unit (§9.2): pause/cancel takes effect at
      // unit boundaries even while a request is in flight.
      if (!_dao.holdsLease(jobId, generation)) return;
      final unit = plan.units[i];
      final messages = <LlmMessage>[
        LlmMessage(role: 'system', content: kTranslationSystemPrompt),
        LlmMessage(role: 'user', content: sourceContext),
        // Deterministic full replay of accepted history (§8.1): user
        // messages rebuild from the plan, assistant turns from the journal,
        // which grows in sync as this loop accepts units.
        for (var j = 0; j < i; j++) ...[
          LlmMessage(role: 'user', content: buildUnitRequest(plan.units[j])),
          LlmMessage(role: 'assistant', content: journal[j].content),
        ],
        LlmMessage(role: 'user', content: buildUnitRequest(unit)),
      ];
      final ({LlmCompletion completion, UnitTranslation validated}) result;
      try {
        result = await _unitWithRetries(
          jobId: jobId,
          generation: generation,
          config: config,
          messages: messages,
          unit: unit,
        );
      } on _LeaseLostDuringBackoff {
        // Cancel/pause/redelivery landed during the backoff sleep: stop
        // without sending anything further; the lease holder owns the job.
        return;
      }
      // A late response from a cancelled/paused worker is discarded without
      // writing — the lease guard is the second gate after the network call.
      if (!_dao.holdsLease(jobId, generation)) return;
      try {
        _dao.acceptUnit(
          jobId: jobId,
          generation: generation,
          unitOrder: i,
          requestId: result.completion.requestId,
          rawContent: result.completion.content,
          usageJson: result.completion.usage == null
              ? null
              : jsonEncode({
                  'prompt_tokens': result.completion.usage!.promptTokens,
                  'completion_tokens':
                      result.completion.usage!.completionTokens,
                  'reasoning_tokens': result.completion.usage!.reasoningTokens,
                }),
          translation: result.validated,
        );
      } on StateError {
        // The lease was lost between the guard and the write (pause/cancel,
        // or a redelivered executor re-claimed the job). That is not a unit
        // failure — stop silently; the new lease holder owns the job. A
        // missing building set (the other StateError) is rethrown.
        if (!_dao.holdsLease(jobId, generation)) return;
        rethrow;
      }
      journal.add((
        unitOrder: i,
        unitId: unit.blockId,
        content: result.completion.content,
      ));
      _notify();
    }
  }

  /// Bounded in-request retry budget for transient transport failures and
  /// transiently malformed replies (PC parity, §8.5): validation runs inside
  /// the loop so a wrong-length or fenced reply scores a corrected retry,
  /// and failed replies never enter the accepted history. Every backoff
  /// sleep is lease-guarded and aborts on cancel/pause/redelivery (§9.2 —
  /// the job must not re-send the article body after the user cancelled).
  Future<({LlmCompletion completion, UnitTranslation validated})>
  _unitWithRetries({
    required String jobId,
    required int generation,
    required TranslationJobConfig config,
    required List<LlmMessage> messages,
    required TranslationPlanUnit unit,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        final completion = await _client.complete(
          model: config.model,
          messages: messages,
          thinkingMode: config.thinkingMode,
          reasoningEffort: config.reasoningEffort,
          timeout: Duration(seconds: config.timeoutSeconds),
        );
        final validated = validateUnitResponse(
          content: completion.content,
          unit: unit,
        );
        return (completion: completion, validated: validated);
      } on LlmException catch (error) {
        if (!error.isTransient || attempt >= config.maxRequestAttempts - 1) {
          rethrow;
        }
        await _sleepUnlessLeaseLost(
          _inRequestBackoff(error),
          jobId,
          generation,
        );
        attempt++;
      } on TranslationProtocolError {
        if (attempt >= config.maxRequestAttempts - 1) rethrow;
        await _sleepUnlessLeaseLost(_backoffFor(0), jobId, generation);
        attempt++;
      }
    }
  }

  /// Lease-guarded backoff sleep (§9.2): the requested wait races a lease
  /// poll — cancel/pause/redelivery during the window (e.g. a `Retry-After`
  /// hold) aborts the sleep within one slice, and the post-sleep check
  /// re-verifies before the next send. A cancelled or superseded worker
  /// never wakes up to re-send the article body.
  Future<void> _sleepUnlessLeaseLost(
    Duration delay,
    String jobId,
    int generation,
  ) async {
    var finished = false;
    Future<void> leaseWatch() async {
      while (!finished) {
        await Future<void>.delayed(_backoffLeaseSlice);
        if (!finished && !_dao.holdsLease(jobId, generation)) return;
      }
    }

    try {
      await Future.any([_sleeper(delay), leaseWatch()]);
    } finally {
      finished = true;
    }
    if (!_dao.holdsLease(jobId, generation)) {
      throw const _LeaseLostDuringBackoff();
    }
  }

  /// Poll granularity of the lease check racing a backoff sleep.
  static const _backoffLeaseSlice = Duration(milliseconds: 250);

  Duration _inRequestBackoff(LlmException error) =>
      error.retryAfterSeconds == null
      ? _backoffFor(0)
      : Duration(seconds: error.retryAfterSeconds!);

  /// Terminal failure of a unit after exhausting every budget (§8.3/§8.5):
  /// transient failures park the job in waiting_retry with scheduler backoff
  /// (bounded rounds); actionable failures stop the job. The active reader
  /// projection is never touched — partial sets cannot activate. A job the
  /// user cancelled/paused meanwhile keeps its status.
  Future<void> _onUnitFailure(
    String jobId,
    TranslationErrorKind kind,
    String detail,
  ) async {
    final job = _dao.getJob(jobId);
    if (job == null || job.status != TranslationJobStatus.running) return;
    final transient =
        kind == TranslationErrorKind.transport ||
        kind == TranslationErrorKind.protocol;
    if (transient && job.retryRound < job.config.maxRetryRounds) {
      final round = job.retryRound + 1;
      _dao.updateStatus(
        jobId,
        TranslationJobStatus.waitingRetry,
        retryRound: round,
        errorKind: kind,
        errorDetail: detail,
      );
      _notify();
      // The backoff window belongs to the scheduler (§8.3). Two delivery
      // paths, one per adapter: the in-process scheduler runs the delayed
      // [TranslationScheduler.schedule] below; on WorkManager, this call is
      // a keep-policy no-op while the current work exists — the worker
      // returns retry for a waiting_retry job and the OS redelivers the same
      // work after its backoff (durable across process death). Both land in
      // [runJob]'s waiting_retry re-entry, which re-queues and continues
      // from the journal.
      _scheduler.schedule(jobId, after: _backoffFor(round));
      return;
    }
    _dao.updateStatus(
      jobId,
      TranslationJobStatus.failed,
      errorKind: kind,
      errorDetail: detail,
    );
    _notify();
  }

  /// Exact-coverage verification → set complete → activation via the library
  /// interface → job completed (§8.2). The reader sees the whole set at once;
  /// if the process dies anywhere here, recover() drives the job back and
  /// this idempotent path finishes it.
  Future<void> _finalize({
    required String jobId,
    required int generation,
    required TranslationPlan plan,
  }) async {
    if (!_dao.holdsLease(jobId, generation)) return;
    final job = _dao.getJob(jobId)!;
    final setId = job.translationSetId;
    if (setId == null) {
      await _cancelStale(job, 'the building set vanished');
      return;
    }
    _verifyCoverage(setId, plan);
    _dao.completeSet(setId);
    try {
      _library.activateTranslation(job.articleId, setId);
    } catch (error) {
      // Only a job still holding its lease may be marked failed: a cancel
      // that landed between completion and activation must stay cancelled.
      final current = _dao.getJob(jobId);
      if (current == null || current.status != TranslationJobStatus.running) {
        return;
      }
      _dao.updateStatus(
        jobId,
        TranslationJobStatus.failed,
        errorKind: TranslationErrorKind.config,
        errorDetail: 'activation rejected: $error',
      );
      _notify();
      return;
    }
    _dao.updateStatus(jobId, TranslationJobStatus.completed);
    _notify();
  }

  void _verifyCoverage(String setId, TranslationPlan plan) {
    final expectedSentences = <String>{};
    final expectedCells = <(String, String)>{};
    for (final unit in plan.units) {
      switch (unit) {
        case SentenceBatchPlanUnit():
          for (final sentence in unit.sentences) {
            expectedSentences.add(sentence.sentenceId);
          }
        case TablePlanUnit():
          for (final cell in unit.cellsInOrder) {
            expectedCells.add((unit.blockId, cell.cellId));
          }
      }
    }
    final actualSentences = _dao.sentenceTranslationIds(setId);
    final actualCells = _dao.tableCellTranslationIds(setId);
    if (!_setsEqual(actualSentences, expectedSentences) ||
        !_pairSetsEqual(actualCells, expectedCells)) {
      throw StateError('coverage mismatch before activation');
    }
  }

  Future<void> _cancelStale(TranslationJobSnapshot job, String reason) async {
    final setId = job.translationSetId;
    if (setId != null) _dao.deleteSet(setId);
    _dao.updateStatus(
      job.jobId,
      TranslationJobStatus.cancelled,
      errorKind: TranslationErrorKind.staleSource,
      errorDetail: reason,
    );
    // Stale results must never activate — and their scheduled executions
    // (e.g. a pending backoff delivery) must not fire either.
    _scheduler.cancelScheduled(job.jobId);
    _onJobTerminated?.call(job.jobId);
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ---- cross-engine observation ----

  Timer? _syncTimer;
  final Map<String, String> _observedJobs = {};

  /// While any job is active, polls the jobs table so progress committed by
  /// the background worker engine (§9.2 — its own connection and its own
  /// in-process notify) still reaches this engine's listeners: bookshelf
  /// badges, the reader status bar and the task page. Stops itself once
  /// every observed job reached a terminal state. Only the UI engine starts
  /// this (opt-in from the composition root when execution is OS-scheduled);
  /// the worker engine observes directly.
  void startExternalSync({Duration interval = const Duration(seconds: 1)}) {
    pollExternalChanges();
    if (_observedJobs.isNotEmpty && _syncTimer == null) {
      _syncTimer = Timer.periodic(interval, (_) => pollExternalChanges());
    }
  }

  /// One observation tick. Public so tests can drive it deterministically.
  void pollExternalChanges() {
    try {
      final active = _dao.activeJobs();
      var changed = false;
      final activeIds = <String>{};
      for (final job in active.values) {
        activeIds.add(job.jobId);
        final signature =
            '${job.status.name}:${job.completedUnits}:'
            '${job.retryRound}:${job.errorKind?.name}';
        if (_observedJobs[job.jobId] != signature) {
          _observedJobs[job.jobId] = signature;
          changed = true;
        }
      }
      // Jobs absent from the active set reached a terminal state (or were
      // deleted with the article). A completion implies the worker engine
      // also activated the set — refresh library projections too (§12.3); a
      // deletion (no row left) also drops any pending scheduled execution
      // (§12.1).
      for (final jobId in _observedJobs.keys.toList()) {
        if (activeIds.contains(jobId)) continue;
        final finalJob = _dao.getJob(jobId);
        _observedJobs.remove(jobId);
        changed = true;
        if (finalJob == null) {
          _scheduler.cancelScheduled(jobId);
          continue;
        }
        if (finalJob.status == TranslationJobStatus.completed) {
          _library.notifyExternalChange();
        }
      }
      if (changed) _notify();
      if (_observedJobs.isEmpty) {
        _syncTimer?.cancel();
        _syncTimer = null;
      }
    } catch (_) {
      // A transiently busy or closing database skips this tick.
    }
  }

  /// Closes the change stream (composition-root disposal).
  void dispose() {
    _syncTimer?.cancel();
    _changes.close();
  }

  static String _pipelineJson(String model) => jsonEncode({
    'provider': kDeepSeekProvider,
    'model': model,
    'prompt_version': kTranslationPromptVersion,
    'client': kTranslationClientVersion,
  });

  static Duration _defaultBackoff(int round) {
    // Exponential with jitter, capped at one minute (§8.5).
    final base = min(60.0, 2.0 * pow(2, round));
    final jittered = base * (0.5 + Random().nextDouble() / 2);
    return Duration(milliseconds: (jittered * 1000).round());
  }

  static bool _setsEqual(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static bool _pairSetsEqual(
    Set<(String, String)> a,
    Set<(String, String)> b,
  ) => a.length == b.length && a.containsAll(b);

  static TranslationErrorKind _toErrorKind(LlmErrorKind kind) => switch (kind) {
    LlmErrorKind.auth => TranslationErrorKind.auth,
    LlmErrorKind.balance => TranslationErrorKind.balance,
    LlmErrorKind.contextLimit => TranslationErrorKind.contextLimit,
    LlmErrorKind.config => TranslationErrorKind.config,
    LlmErrorKind.protocol => TranslationErrorKind.protocol,
    // Transient transport failures (rate limit, 5xx, timeouts, refused).
    LlmErrorKind.rateLimit ||
    LlmErrorKind.server ||
    LlmErrorKind.timeout => TranslationErrorKind.transport,
  };
}
