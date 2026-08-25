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

/// Conservative deepseek-chat context window (tokens). The queue precheck
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
  }) : _dao = dao,
       _library = library,
       _client = client,
       _secrets = secrets,
       _scheduler = scheduler,
       _sleeper = sleeper ?? Future<void>.delayed,
       _backoffFor = backoffFor ?? _defaultBackoff;

  final TranslationDao _dao;
  final LibraryService _library;
  final LlmCompletionClient _client;
  final TranslationSecretStore _secrets;
  final TranslationScheduler _scheduler;
  final Future<void> Function(Duration) _sleeper;
  final Duration Function(int retryRound) _backoffFor;

  final StreamController<void> _changes = StreamController.broadcast();

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
    final contextChars =
        kTranslationSystemPrompt.length + context.length;
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
    final tableCount = content.blocks
        .whereType<InstalledTableBlock>()
        .length;
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
    _notify();
  }

  void pause(String jobId) {
    final job = _dao.getJob(jobId);
    if (job == null || !job.isActive) return;
    _dao.updateStatus(jobId, TranslationJobStatus.paused);
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
  Future<void> recover() async {
    final stale = <String>[];
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
      _dao.requeue(job.jobId);
      stale.add(job.jobId);
    }
    for (final jobId in stale) {
      _scheduler.schedule(jobId);
    }
  }

  // ---- execution ----

  /// One execution attempt: claim → replay history from the journal →
  /// translate pending units → verify coverage → activate atomically.
  /// Invoked by the scheduler; safe to call repeatedly (idempotent guards).
  Future<void> runJob(String jobId) async {
    var job = _dao.getJob(jobId);
    if (job == null || job.status != TranslationJobStatus.queued) return;

    final article = _library.getArticle(job.articleId);
    if (article == null || article.structureSha256 != job.structureSha256) {
      await _cancelStale(job, 'the article source changed');
      return;
    }
    final content = _library.getContent(job.articleId);
    if (content == null) {
      await _cancelStale(job, 'the article is no longer readable');
      return;
    }
    final plan = buildTranslationPlan(content.blocks);
    if (plan.units.length != job.totalUnits) {
      await _cancelStale(job, 'the article structure changed');
      return;
    }

    final generation = _dao.claim(jobId);
    if (generation == null) return;
    job = _dao.getJob(jobId)!;
    final config = job.config;

    final journal = _dao.acceptedUnits(jobId);
    // Reconciliation: the journal must be a prefix of the current plan.
    for (var i = 0; i < journal.length; i++) {
      if (journal[i].unitId != plan.units[i].blockId) {
        await _cancelStale(job, 'the accepted journal does not match the '
            'article structure');
        return;
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
      await _onUnitFailure(
        jobId,
        TranslationErrorKind.config,
        error.message,
      );
    }
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
      final result = await _unitWithRetries(config, messages, unit);
      // A late response from a cancelled/paused worker is discarded without
      // writing — the lease guard is the second gate after the network call.
      if (!_dao.holdsLease(jobId, generation)) return;
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
      journal.add(
        (unitOrder: i, unitId: unit.blockId, content: result.completion.content),
      );
      _notify();
    }
  }

  /// Bounded in-request retry budget for transient transport failures and
  /// transiently malformed replies (PC parity, §8.5): validation runs inside
  /// the loop so a wrong-length or fenced reply scores a corrected retry,
  /// and failed replies never enter the accepted history.
  Future<({LlmCompletion completion, UnitTranslation validated})>
  _unitWithRetries(
    TranslationJobConfig config,
    List<LlmMessage> messages,
    TranslationPlanUnit unit,
  ) async {
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
        await _sleeper(_inRequestBackoff(error));
        attempt++;
      } on TranslationProtocolError {
        if (attempt >= config.maxRequestAttempts - 1) rethrow;
        await _sleeper(_backoffFor(0));
        attempt++;
      }
    }
  }

  Duration _inRequestBackoff(LlmException error) => error.retryAfterSeconds ==
      null
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
    final transient = kind == TranslationErrorKind.transport ||
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
      unawaited(_requeueAfterBackoff(jobId, round));
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

  Future<void> _requeueAfterBackoff(String jobId, int round) async {
    await _sleeper(_backoffFor(round));
    final job = _dao.getJob(jobId);
    if (job == null || job.status != TranslationJobStatus.waitingRetry) {
      return;
    }
    _dao.requeue(jobId);
    _notify();
    _scheduler.schedule(jobId);
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

  Future<void> _cancelStale(
    TranslationJobSnapshot job,
    String reason,
  ) async {
    final setId = job.translationSetId;
    if (setId != null) _dao.deleteSet(setId);
    _dao.updateStatus(
      job.jobId,
      TranslationJobStatus.cancelled,
      errorKind: TranslationErrorKind.staleSource,
      errorDetail: reason,
    );
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Closes the change stream (composition-root disposal).
  void dispose() => _changes.close();

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

  static TranslationErrorKind _toErrorKind(LlmErrorKind kind) => switch (
    kind
  ) {
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
