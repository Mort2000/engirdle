/// LLM completion seam (design §7.3): the translation module depends on this
/// port, not on DeepSeek or any HTTP SDK. Production uses
/// [DeepSeekMobileAdapter]; tests use a scripted in-memory adapter.
library;

enum LlmErrorKind {
  /// 401/403 — the key was rejected. Actionable: reconfigure, never retry.
  auth,

  /// 402 — insufficient balance.
  balance,

  /// 429 — provider throttling. Transient.
  rateLimit,

  /// 5xx / connection failures. Transient.
  server,

  /// Request timed out. Transient.
  timeout,

  /// 400/413 with a context-window marker — fail explicitly, never compress.
  contextLimit,

  /// Malformed model reply or provider rejection without a known status.
  /// Transiently malformed replies share the bounded retry budget (as PC).
  protocol,

  /// Client-side misconfiguration (missing key, wrong origin, bad model).
  config,
}

class LlmException implements Exception {
  const LlmException(this.kind, this.message, {this.statusCode, this.retryAfterSeconds});

  final LlmErrorKind kind;
  final String message;
  final int? statusCode;

  /// Provider-advised wait (Retry-After on 429) when present; backoff
  /// prefers it over the computed schedule (design §8.5).
  final int? retryAfterSeconds;

  /// May succeed on a bounded retry within one unit request (§8.5).
  bool get isTransient =>
      kind == LlmErrorKind.rateLimit ||
      kind == LlmErrorKind.server ||
      kind == LlmErrorKind.timeout ||
      kind == LlmErrorKind.protocol;

  @override
  String toString() =>
      'LlmException(${kind.name}: $message'
      '${statusCode == null ? '' : ', HTTP $statusCode'})';
}

class LlmUsage {
  const LlmUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.reasoningTokens,
  });

  final int promptTokens;
  final int completionTokens;
  final int reasoningTokens;
}

class LlmCompletion {
  const LlmCompletion({
    required this.content,
    required this.finishReason,
    required this.requestId,
    this.usage,
  });

  final String content;
  final String finishReason;
  final String requestId;
  final LlmUsage? usage;
}

class LlmMessage {
  const LlmMessage({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

abstract interface class LlmCompletionClient {
  /// Completes one chat turn. Throws [LlmException] with a classified kind.
  Future<LlmCompletion> complete({
    required String model,
    required List<LlmMessage> messages,
    required String thinkingMode,
    required String reasoningEffort,
    required Duration timeout,
  });

  /// Available model ids — used by the settings page connection test.
  Future<List<String>> listModels({required Duration timeout});
}

/// Substrings in a 400/413 body that indicate the context window is
/// exhausted. Kept specific so ordinary 400s are not misclassified (mirrors
/// the PC client).
const List<String> kContextLimitMarkers = [
  'context length',
  'context window',
  'maximum context',
  'exceeds the context',
  'input length exceeds',
  'too long',
];

/// Pure provider-failure classifier shared by the adapter and its tests.
LlmException classifyLlmError({
  int? statusCode,
  String message = '',
  bool timedOut = false,
  bool connectionFailed = false,
  Map<String, String> headers = const {},
}) {
  if (timedOut) {
    return LlmException(LlmErrorKind.timeout, 'request timed out',
        statusCode: statusCode);
  }
  if (connectionFailed) {
    return LlmException(LlmErrorKind.server, 'connection to provider failed',
        statusCode: statusCode);
  }
  final status = statusCode;
  if (status == null) {
    return LlmException(LlmErrorKind.server, 'unknown provider error');
  }
  final lowered = message.toLowerCase();
  switch (status) {
    case 401 || 403:
      return LlmException(
        LlmErrorKind.auth,
        'provider rejected the API key',
        statusCode: status,
      );
    case 402:
      return LlmException(
        LlmErrorKind.balance,
        'insufficient account balance',
        statusCode: status,
      );
    case 429:
      return LlmException(
        LlmErrorKind.rateLimit,
        'provider rate limit',
        statusCode: status,
        retryAfterSeconds: _retryAfterSeconds(headers),
      );
    case 400 || 413:
      if (kContextLimitMarkers.any(lowered.contains)) {
        return LlmException(
          LlmErrorKind.contextLimit,
          'accumulated context exceeds the model window',
          statusCode: status,
        );
      }
      return LlmException(
        LlmErrorKind.protocol,
        'provider rejected the request',
        statusCode: status,
      );
    default:
      if (status >= 500 && status < 600) {
        return LlmException(
          LlmErrorKind.server,
          'provider server error',
          statusCode: status,
        );
      }
      return LlmException(
        LlmErrorKind.protocol,
        'provider rejected the request',
        statusCode: status,
      );
  }
}

/// Extracts a whole-second Retry-After value if the provider sent one.
int? _retryAfterSeconds(Map<String, String> headers) {
  final raw = headers['retry-after'];
  if (raw == null) return null;
  return int.tryParse(raw.trim());
}
