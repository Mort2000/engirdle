import 'dart:async';

import 'package:engirdle_mobile/app/dependencies.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/features/library/domain/article_install.dart';
import 'package:engirdle_mobile/features/reader/presentation/reader_page.dart';
import 'package:engirdle_mobile/features/translation/application/llm_client.dart';
import 'package:engirdle_mobile/features/translation/presentation/llm_settings_page.dart';
import 'package:engirdle_mobile/features/library/presentation/bookshelf_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_helpers.dart';

/// Scripted LLM client for widget tests: full happy-path replies by default,
/// or a gate that holds the first request in flight (running-job UI states).
class UiScriptedClient implements LlmCompletionClient {
  UiScriptedClient();

  /// When set, the next reply waits on this gate (running-job UI states).
  Completer<String>? gate;
  var calls = 0;

  static const _replies = [
    '["标题译文"]',
    '["保持 ‰0‰ 分离。", "参见官方文档了解详情。"]',
    '{"block_id": "block-3", "columns": 2, '
        '"alignments": ["default", "center"], '
        '"header": [{"cell_id": "c0", "text": "层"}, '
        '{"cell_id": "c1", "text": "文件"}], '
        '"rows": [[{"cell_id": "c2", "text": "基座"}, '
        '{"cell_id": "c3", "text": "‰0‰"}]]}',
  ];

  @override
  Future<LlmCompletion> complete({
    required String model,
    required List<LlmMessage> messages,
    required String thinkingMode,
    required String reasoningEffort,
    required Duration timeout,
  }) async {
    final held = gate;
    if (held != null) {
      gate = null;
      final content = await held.future;
      calls++;
      return LlmCompletion(
        content: content,
        finishReason: 'stop',
        requestId: 'gated-$calls',
      );
    }
    final reply = _replies[calls % _replies.length];
    calls++;
    return LlmCompletion(
      content: reply,
      finishReason: 'stop',
      requestId: 'req-$calls',
    );
  }

  @override
  Future<List<String>> listModels({required Duration timeout}) async => [
    'deepseek-v4-flash',
  ];
}

Future<void> installReadableArticle(AppDependencies deps) async {
  ArticleRun plain(String text) =>
      ArticleRun(kind: ArticleRunKind.plain, text: text);
  deps.library.commitInstall(
    ValidatedArticleImport(
      articleId: 'a1',
      revision: 1,
      artifactRevision: 1,
      title: 'Contract Article',
      source: const ArticleSource(author: 'Engirdle'),
      origin: 'paste',
      formatVersion: 'local-1',
      sourceSha256: 'raw-sha',
      normalizedSha256: 'norm-sha',
      sourceSyntax: 'plain_text',
      structureSha256: 'sha-1',
      segmenterVersion: 'engirdle-segmenter-dart@3',
      blocks: [
        ParsedTextBlock(
          blockId: 'block-1',
          order: 0,
          kind: ArticleTextKind.heading,
          level: 2,
          sentences: [
            SentenceContent(
              sentenceId: 's1',
              order: 0,
              text: 'Title heading.',
              runs: [plain('Title heading.')],
            ),
          ],
        ),
        ParsedTextBlock(
          blockId: 'block-2',
          order: 1,
          kind: ArticleTextKind.paragraph,
          sentences: [
            SentenceContent(
              sentenceId: 's2',
              order: 0,
              text: 'Keep the source text apart.',
              runs: [
                plain('Keep the '),
                ArticleRun(kind: ArticleRunKind.code, text: 'source text'),
                plain(' apart.'),
              ],
            ),
            SentenceContent(
              sentenceId: 's3',
              order: 1,
              text: 'See https://example.com/x for details.',
              runs: [plain('See https://example.com/x for details.')],
            ),
          ],
        ),
        ParsedTableBlock(
          blockId: 'block-3',
          order: 2,
          alignments: [TableAlignment.inherit, TableAlignment.center],
          translationById: const {},
          header: [
            ParsedTableCell(
              cellId: 'c0',
              text: 'Layer',
              runs: [plain('Layer')],
            ),
            ParsedTableCell(
              cellId: 'c1',
              text: 'File',
              runs: [plain('File')],
            ),
          ],
          rows: [
            [
              ParsedTableCell(
                cellId: 'c2',
                text: 'base',
                runs: [plain('base')],
              ),
              ParsedTableCell(
                cellId: 'c3',
                text: 'article.json',
                runs: [
                  ArticleRun(kind: ArticleRunKind.code, text: 'article.json'),
                ],
              ),
            ],
          ],
        ),
      ],
      manifestJson: '{}',
      attributionJson: '{}',
      artifactSizeBytes: 42,
      artifactSha256: 'raw-sha',
    ),
  );
}

void main() {
  late AppDependencies deps;
  late UiScriptedClient client;

  // Dependencies are built outside testWidgets: FakeAsync never advances the
  // real IO futures inside newTestDependencies (same note as the reader tests).
  setUp(() async {
    client = UiScriptedClient();
    deps = await newTestDependencies(translationClient: client);
  });

  testWidgets('settings page stores the key without echoing it', (tester) async {
    await tester.pumpWidget(wrapTestWidget(deps, const LlmSettingsPage()));

    expect(find.text('未保存'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('api-key-field')),
      'sk-secret-value',
    );
    await tester.ensureVisible(find.text('保存密钥'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存密钥'));
    await tester.pumpAndSettle();

    expect(find.text('已保存（出于安全考虑不回显内容）'), findsOneWidget);
    // The key never shows up in the widget tree.
    expect(find.textContaining('sk-secret-value'), findsNothing);
    expect(deps.translationSettings.profile()!.model, 'deepseek-v4-flash');

    await tester.ensureVisible(find.text('测试连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接成功，所选模型可用。'), findsOneWidget);
  });

  testWidgets('reader translation flow activates bilingual reading',
      (tester) async {
    await installReadableArticle(deps);
    await deps.translationSettings.configure(apiKey: 'sk-test');

    await tester.pumpWidget(
      wrapTestWidget(deps, ReaderPage(articleId: 'a1')),
    );
    await tester.pumpAndSettle();

    // The translate entry exists only while no translation is active.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('翻译文章'), findsOneWidget);

    await tester.tap(find.text('翻译文章'));
    await tester.pumpAndSettle();
    // The confirmation shows the privacy statement and estimate (§8.6).
    expect(find.textContaining('全文将发送'), findsOneWidget);
    expect(find.textContaining('tokens'), findsOneWidget);

    await tester.tap(find.text('开始翻译'));
    await tester.pumpAndSettle();

    expect(deps.library.getContent('a1')!.capabilities.hasTranslation, isTrue);
    // The reader refreshed its projection without leaving the page: the
    // bilingual mode is now offered, and the article reads in it.
    await tester.tap(find.byIcon(Icons.translate));
    await tester.pumpAndSettle();
    expect(find.text('英中对照'), findsOneWidget);
    await tester.tap(find.text('英中对照'));
    await tester.pumpAndSettle();
    expect(find.text('保持 source text 分离。'), findsOneWidget);
  });

  testWidgets('bookshelf shows the live translation progress badge',
      (tester) async {
    // A saved endpoint skips the first-run setup page that would otherwise
    // cover the bookshelf.
    deps.connection.saveUrl('http://192.168.1.12:8766');
    final gate = Completer<String>();
    client.gate = gate;
    await installReadableArticle(deps);
    await deps.translationSettings.configure(apiKey: 'sk-test');

    await deps.translation.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.now(),
    );
    await tester.pumpWidget(wrapTestWidget(deps, const BookshelfPage()));
    await tester.pumpAndSettle();

    expect(find.textContaining('翻译中'), findsOneWidget);
    expect(find.text('原文'), findsNothing);

    gate.complete('["标题译文"]');
    await tester.pumpAndSettle();
    expect(
      deps.library.getContent('a1')!.capabilities.hasTranslation,
      isTrue,
    );
  });
}
