import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../application/llm_client.dart';
import '../application/secret_store.dart';
import '../domain/translation_errors.dart';

/// Production LLM adapter: the official DeepSeek HTTPS endpoint only (design
/// §10.2). The origin is fixed — never configurable — and re-validated before
/// every request, so the stored key can only ever be sent to
/// api.deepseek.com over the system trust chain (no TLS bypass exists).
const String kDeepSeekOfficialOrigin = 'https://api.deepseek.com';
const String kDeepSeekProvider = 'deepseek';
const String kDeepSeekDefaultModel = 'deepseek-v4-flash';
const String kDeepSeekSecretAlias = 'deepseek-api-key';

/// Minimal HTTP seam under the adapter: dart:io in production, scriptable in
/// tests. Kept raw (status/headers/body) so classification stays in the
/// adapter and both sides share the same [classifyLlmError].
abstract interface class HttpTransport {
  Future<HttpTransportResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
    required Duration timeout,
  });
}

class HttpTransportResponse {
  const HttpTransportResponse({
    required this.statusCode,
    this.headers = const {},
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;
}

/// Failure of the transport itself (no usable HTTP status).
class HttpTransportFailure implements Exception {
  const HttpTransportFailure({this.timedOut = false, this.message = ''});

  final bool timedOut;
  final String message;
}

class IoHttpTransport implements HttpTransport {
  const IoHttpTransport();

  @override
  Future<HttpTransportResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
    required Duration timeout,
  }) async {
    final client = HttpClient();
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(timeout, onTimeout: () => throw const HttpTransportFailure(timedOut: true));
      for (final header in headers.entries) {
        request.headers.set(header.key, header.value);
      }
      if (body != null) {
        // Write raw UTF-8 bytes: request.write() would encode non-ASCII
        // content as latin-1 when the content-type header has no charset.
        final bodyBytes = utf8.encode(body);
        request.headers.contentLength = bodyBytes.length;
        request.add(bodyBytes);
      }
      final response = await request.close().timeout(
        timeout,
        onTimeout: () => throw const HttpTransportFailure(timedOut: true),
      );
      final bytes = await response
          .fold<List<int>>([], (acc, chunk) => acc..addAll(chunk))
          .timeout(timeout, onTimeout: () => throw const HttpTransportFailure(timedOut: true));
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(',');
      });
      return HttpTransportResponse(
        statusCode: response.statusCode,
        headers: responseHeaders,
        body: utf8.decode(bytes),
      );
    } on SocketException catch (error) {
      throw HttpTransportFailure(message: error.message);
    } finally {
      client.close(force: true);
    }
  }
}

class DeepSeekMobileAdapter implements LlmCompletionClient {
  DeepSeekMobileAdapter({
    required this.secrets,
    HttpTransport transport = const IoHttpTransport(),
    String origin = kDeepSeekOfficialOrigin,
  }) : _transport = transport {
    // First gate at construction; the second runs before every request.
    if (origin != kDeepSeekOfficialOrigin) {
      throw TranslationConfigError(
        'deepseek adapter refuses non-official origin "$origin"',
      );
    }
  }

  final TranslationSecretStore secrets;
  final HttpTransport _transport;

  @override
  Future<LlmCompletion> complete({
    required String model,
    required List<LlmMessage> messages,
    required String thinkingMode,
    required String reasoningEffort,
    required Duration timeout,
  }) async {
    final key = await _requireKey();
    final response = await _send(
      'POST',
      Uri.parse('$kDeepSeekOfficialOrigin/chat/completions'),
      headers: {
        'authorization': 'Bearer $key',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'messages': [for (final message in messages) message.toJson()],
        'stream': false,
        'thinking': {'type': thinkingMode},
        'reasoning_effort': reasoningEffort,
      }),
      timeout: timeout,
    );
    final decoded = _decodeJson(response.body);
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const LlmException(LlmErrorKind.protocol, 'no completion choices');
    }
    final choice = choices.first as Map<String, Object?>;
    final message = choice['message'];
    if (message is! Map<String, Object?>) {
      throw const LlmException(LlmErrorKind.protocol, 'no message content');
    }
    return LlmCompletion(
      content: (message['content'] as String?) ?? '',
      finishReason: (choice['finish_reason'] as String?) ?? '',
      requestId: (decoded['id'] as String?) ?? '',
      usage: _usage(decoded['usage']),
    );
  }

  @override
  Future<List<String>> listModels({required Duration timeout}) async {
    final key = await _requireKey();
    final response = await _send(
      'GET',
      Uri.parse('$kDeepSeekOfficialOrigin/models'),
      headers: {'authorization': 'Bearer $key'},
      timeout: timeout,
    );
    final decoded = _decodeJson(response.body);
    final data = decoded['data'];
    if (data is! List) {
      throw const LlmException(LlmErrorKind.protocol, 'no models payload');
    }
    return [
      for (final model in data)
        if (model is Map<String, Object?> && model['id'] is String)
          model['id']! as String,
    ];
  }

  Future<String> _requireKey() async {
    final key = await secrets.read(kDeepSeekSecretAlias);
    if (key == null || key.trim().isEmpty) {
      throw const LlmException(
        LlmErrorKind.config,
        'API key is not configured; add it in translation settings',
      );
    }
    return key.trim();
  }

  Future<HttpTransportResponse> _send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
    required Duration timeout,
  }) async {
    // Second gate, every request: the fixed origin again.
    if (!uri.toString().startsWith('$kDeepSeekOfficialOrigin/')) {
      throw TranslationConfigError(
        'deepseek adapter refuses non-official url "$uri"',
      );
    }
    try {
      final response = await _transport.send(
        method,
        uri,
        headers: headers,
        body: body,
        timeout: timeout,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw classifyLlmError(
          statusCode: response.statusCode,
          message: response.body,
          headers: response.headers,
        );
      }
      return response;
    } on HttpTransportFailure catch (failure) {
      throw classifyLlmError(
        timedOut: failure.timedOut,
        message: failure.message,
        connectionFailed: !failure.timedOut,
      );
    }
  }

  static Map<String, Object?> _decodeJson(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) return decoded;
      throw const LlmException(LlmErrorKind.protocol, 'non-object payload');
    } on FormatException {
      throw const LlmException(LlmErrorKind.protocol, 'invalid JSON payload');
    }
  }

  static LlmUsage? _usage(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final details = raw['completion_tokens_details'];
    return LlmUsage(
      promptTokens: (raw['prompt_tokens'] as int?) ?? 0,
      completionTokens: (raw['completion_tokens'] as int?) ?? 0,
      reasoningTokens:
          details is Map<String, Object?>
          ? (details['reasoning_tokens'] as int?) ?? 0
          : 0,
    );
  }
}
