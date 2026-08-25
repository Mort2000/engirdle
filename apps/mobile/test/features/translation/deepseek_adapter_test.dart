import 'dart:convert';

import 'package:engirdle_mobile/features/translation/application/llm_client.dart';
import 'package:engirdle_mobile/features/translation/domain/translation_errors.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/deepseek_adapter.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/secret_stores.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scriptable transport: records the last request and replies with the
/// scripted response or failure.
class FakeTransport implements HttpTransport {
  FakeTransport({this.response, this.failure});

  HttpTransportResponse? response;
  HttpTransportFailure? failure;

  String? method;
  Uri? uri;
  Map<String, String> headers = {};
  String? body;

  @override
  Future<HttpTransportResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
    required Duration timeout,
  }) async {
    this.method = method;
    this.uri = uri;
    this.headers = headers;
    this.body = body;
    if (failure != null) throw failure!;
    return response!;
  }
}

void main() {
  late InMemorySecretStore secrets;
  late FakeTransport transport;

  setUp(() {
    secrets = InMemorySecretStore();
    transport = FakeTransport();
    secrets.write('deepseek-api-key', 'sk-test-123');
  });

  DeepSeekMobileAdapter adapter() => DeepSeekMobileAdapter(
    secrets: secrets,
    transport: transport,
  );

  test('construction refuses a non-official origin', () {
    expect(
      () => DeepSeekMobileAdapter(
        secrets: secrets,
        transport: transport,
        origin: 'https://evil.example',
      ),
      throwsA(isA<TranslationConfigError>()),
    );
  });

  test('complete sends the OpenAI-compatible body and parses the reply', () async {
    transport.response = HttpTransportResponse(
      statusCode: 200,
      body: jsonEncode({
        'id': 'req-77',
        'choices': [
          {
            'message': {'role': 'assistant', 'content': '["译文"]'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 1200,
          'completion_tokens': 30,
          'completion_tokens_details': {'reasoning_tokens': 12},
        },
      }),
    );

    final completion = await adapter().complete(
      model: 'deepseek-chat',
      messages: const [
        LlmMessage(role: 'system', content: 'system text'),
        LlmMessage(role: 'user', content: 'user text'),
      ],
      thinkingMode: 'enabled',
      reasoningEffort: 'max',
      timeout: const Duration(seconds: 5),
    );

    expect(completion.content, '["译文"]');
    expect(completion.finishReason, 'stop');
    expect(completion.requestId, 'req-77');
    expect(completion.usage!.reasoningTokens, 12);
    expect(completion.usage!.promptTokens, 1200);

    // Request shape: official origin, Bearer key from the secret store,
    // thinking/reasoning extra body, full message replay.
    expect(transport.method, 'POST');
    expect(transport.uri.toString(),
        'https://api.deepseek.com/chat/completions');
    expect(transport.headers['authorization'], 'Bearer sk-test-123');
    final sent = jsonDecode(transport.body!) as Map<String, Object?>;
    expect(sent['model'], 'deepseek-chat');
    expect(sent['stream'], false);
    expect(sent['thinking'], {'type': 'enabled'});
    expect(sent['reasoning_effort'], 'max');
    expect((sent['messages'] as List).length, 2);
  });

  test('a missing key fails as config before any request', () async {
    await secrets.delete('deepseek-api-key');
    await expectLater(
      adapter().complete(
        model: 'deepseek-chat',
        messages: const [LlmMessage(role: 'user', content: 'x')],
        thinkingMode: 'enabled',
        reasoningEffort: 'max',
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<LlmException>().having(
          (e) => e.kind,
          'kind',
          LlmErrorKind.config,
        ),
      ),
    );
    expect(transport.uri, isNull);
  });

  for (final (status, body, expected) in [
    (401, '', LlmErrorKind.auth),
    (403, '', LlmErrorKind.auth),
    (402, '', LlmErrorKind.balance),
    (429, '', LlmErrorKind.rateLimit),
    (500, '', LlmErrorKind.server),
    (503, '', LlmErrorKind.server),
    (400, 'Input length exceeds context length', LlmErrorKind.contextLimit),
    (413, 'request too long', LlmErrorKind.contextLimit),
    (400, 'messages length must be >= 1', LlmErrorKind.protocol),
  ]) {
    test('HTTP $status maps to ${expected.name}', () async {
      transport.response = HttpTransportResponse(statusCode: status, body: body);
      await expectLater(
        adapter().complete(
          model: 'deepseek-chat',
          messages: const [LlmMessage(role: 'user', content: 'x')],
          thinkingMode: 'enabled',
          reasoningEffort: 'max',
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          isA<LlmException>()
              .having((e) => e.kind, 'kind', expected)
              .having((e) => e.statusCode, 'status', status),
        ),
      );
    });
  }

  test('transport timeout and connection failure map to transient kinds', () async {
    transport.failure = const HttpTransportFailure(timedOut: true);
    await expectLater(
      adapter().complete(
        model: 'deepseek-chat',
        messages: const [LlmMessage(role: 'user', content: 'x')],
        thinkingMode: 'enabled',
        reasoningEffort: 'max',
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<LlmException>().having(
          (e) => e.kind,
          'kind',
          LlmErrorKind.timeout,
        ),
      ),
    );
    transport.failure = const HttpTransportFailure(message: 'refused');
    await expectLater(
      adapter().complete(
        model: 'deepseek-chat',
        messages: const [LlmMessage(role: 'user', content: 'x')],
        thinkingMode: 'enabled',
        reasoningEffort: 'max',
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<LlmException>().having(
          (e) => e.kind,
          'kind',
          LlmErrorKind.server,
        ),
      ),
    );
  });

  test('listModels returns the provider model ids', () async {
    transport.response = HttpTransportResponse(
      statusCode: 200,
      body: jsonEncode({
        'data': [
          {'id': 'deepseek-chat'},
          {'id': 'deepseek-reasoner'},
        ],
      }),
    );
    final models = await adapter().listModels(
      timeout: const Duration(seconds: 5),
    );
    expect(models, ['deepseek-chat', 'deepseek-reasoner']);
    expect(transport.uri.toString(), 'https://api.deepseek.com/models');
  });
}
