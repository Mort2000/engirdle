/// Domain types for the mobile translation module (design §8). The job row
/// is the task source of truth: status, lease generation and progress live
/// only here — never in the scheduler — so UI, process restarts and (phase 4)
/// WorkManager all observe the same state machine.
enum TranslationJobStatus {
  queued,
  running,
  waitingRetry,
  paused,
  failed,
  completed,
  cancelled;

  /// Storage wire format (snake_case, matching the v7 partial index and
  /// every SQL status list).
  String get wire => switch (this) {
    TranslationJobStatus.queued => 'queued',
    TranslationJobStatus.running => 'running',
    TranslationJobStatus.waitingRetry => 'waiting_retry',
    TranslationJobStatus.paused => 'paused',
    TranslationJobStatus.failed => 'failed',
    TranslationJobStatus.completed => 'completed',
    TranslationJobStatus.cancelled => 'cancelled',
  };

  static TranslationJobStatus fromName(String name) =>
      TranslationJobStatus.values.firstWhere(
        (s) => s.wire == name,
        orElse: () => TranslationJobStatus.queued,
      );

  /// Statuses holding the one-job-per-article+locale slot (§8.4).
  bool get occupiesSlot =>
      this == TranslationJobStatus.queued ||
      this == TranslationJobStatus.running ||
      this == TranslationJobStatus.waitingRetry ||
      this == TranslationJobStatus.paused;

  bool get isTerminal =>
      this == TranslationJobStatus.completed ||
      this == TranslationJobStatus.cancelled;
}

/// Failure categories (design §8.5). `transport`/`protocol` are transient —
/// they surface as waiting_retry rounds, then failed(transient exhausted).
/// Everything else stops the job as an actionable failure.
enum TranslationErrorKind {
  transport,
  protocol,
  auth,
  balance,
  contextLimit,
  config,
  staleSource;

  static TranslationErrorKind? fromName(String? name) =>
      name == null
          ? null
          : TranslationErrorKind.values
                .where((k) => k.name == name)
                .firstOrNull;

  String get wire => name;
}

/// The frozen per-job configuration snapshot (§8.4): settings changes after
/// queue only affect new jobs.
class TranslationJobConfig {
  const TranslationJobConfig({
    required this.provider,
    required this.origin,
    required this.model,
    required this.promptVersion,
    required this.thinkingMode,
    required this.reasoningEffort,
    required this.timeoutSeconds,
    required this.maxRequestAttempts,
    required this.maxRetryRounds,
    required this.clientVersion,
  });

  final String provider;
  final String origin;
  final String model;
  final String promptVersion;
  final String thinkingMode;
  final String reasoningEffort;
  final int timeoutSeconds;
  final int maxRequestAttempts;
  final int maxRetryRounds;
  final String clientVersion;

  Map<String, Object?> toJson() => {
    'provider': provider,
    'origin': origin,
    'model': model,
    'prompt_version': promptVersion,
    'thinking': thinkingMode,
    'reasoning_effort': reasoningEffort,
    'timeout_seconds': timeoutSeconds,
    'max_request_attempts': maxRequestAttempts,
    'max_retry_rounds': maxRetryRounds,
    'client_version': clientVersion,
  };

  static TranslationJobConfig fromJson(Map<String, Object?> json) =>
      TranslationJobConfig(
        provider: json['provider']! as String,
        origin: json['origin']! as String,
        model: json['model']! as String,
        promptVersion: json['prompt_version']! as String,
        thinkingMode: json['thinking']! as String,
        reasoningEffort: json['reasoning_effort']! as String,
        timeoutSeconds: json['timeout_seconds']! as int,
        maxRequestAttempts: json['max_request_attempts']! as int,
        maxRetryRounds: json['max_retry_rounds']! as int,
        clientVersion: json['client_version']! as String,
      );
}

class TranslationJobSnapshot {
  const TranslationJobSnapshot({
    required this.jobId,
    required this.articleId,
    required this.structureSha256,
    required this.targetLocale,
    required this.status,
    required this.generation,
    required this.completedUnits,
    required this.totalUnits,
    required this.retryRound,
    required this.config,
    required this.createdAt,
    required this.updatedAt,
    this.translationSetId,
    this.errorKind,
    this.errorDetail,
    this.startedAt,
    this.finishedAt,
  });

  final String jobId;
  final String articleId;
  final String structureSha256;
  final String targetLocale;
  final String? translationSetId;

  final TranslationJobStatus status;

  /// Lease token of the latest claim; stale workers fail the write guard.
  final int generation;
  final int completedUnits;
  final int totalUnits;
  final int retryRound;
  final TranslationErrorKind? errorKind;
  final String? errorDetail;
  final TranslationJobConfig config;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isActive => status.occupiesSlot;
}

/// Non-secret LLM profile (design §10.1/§11.1): the API key itself lives only
/// in the Keystore-backed secret store under [secretAlias] — never in this
/// row, logs, WorkManager data or backups.
class LlmProfile {
  const LlmProfile({
    required this.provider,
    required this.origin,
    required this.model,
    required this.secretAlias,
    required this.wifiOnly,
    required this.chargingOnly,
    required this.updatedAt,
  });

  final String provider;

  /// Fixed official provider origin; changing it requires re-entering the
  /// key (origin binding, design §10.2).
  final String origin;
  final String model;
  final String secretAlias;
  final bool wifiOnly;
  final bool chargingOnly;
  final DateTime updatedAt;

  LlmProfile copyWith({String? model, bool? wifiOnly, bool? chargingOnly}) =>
      LlmProfile(
        provider: provider,
        origin: origin,
        model: model ?? this.model,
        secretAlias: secretAlias,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        chargingOnly: chargingOnly ?? this.chargingOnly,
        updatedAt: DateTime.now().toUtc(),
      );
}

/// Cost/context precheck result shown on the confirmation page (design §8.6).
class TranslationEstimate {
  const TranslationEstimate({
    required this.articleChars,
    required this.sentenceCount,
    required this.tableCount,
    required this.unitCount,
    required this.minInputTokens,
    required this.maxInputTokens,
    required this.contextTooLarge,
  });

  final int articleChars;
  final int sentenceCount;
  final int tableCount;
  final int unitCount;

  /// Conservative full-replay input token range (estimate only).
  final int minInputTokens;
  final int maxInputTokens;

  /// True when even the first request cannot fit the model window: queue is
  /// refused instead of starting a job doomed to fail mid-way.
  final bool contextTooLarge;
}
