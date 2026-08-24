import 'package:engirdle_mobile/app/dependencies.dart';
import 'package:engirdle_mobile/features/library/domain/article_install.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/manifest.dart';
import 'package:engirdle_mobile/features/reader/presentation/content_block_view.dart';
import 'package:engirdle_mobile/features/reader/presentation/reader_page.dart';
import 'package:engirdle_mobile/features/reader/presentation/sheets.dart';
import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/reader/presentation/sentence_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

/// v1.1 static block presentations across the three reading modes
/// (MOB-READ-002): tables honor alignment and stack translations in the same
/// grid cell, code renders monospaced and copyable, dividers render once —
/// and none of them expose sentence menus or playback.
void main() {
  final blocks = <InstalledBlock>[
    InstalledTableBlock(
      blockId: 'tb',
      order: 0,
      alignments: [TableAlignment.inherit, TableAlignment.center],
      header: const [
        InstalledTableCell(
          cellId: 'c0',
          text: 'Feature',
          runs: [ArticleRun(kind: ArticleRunKind.plain, text: 'Feature')],
        ),
        InstalledTableCell(
          cellId: 'c1',
          text: 'Status',
          runs: [ArticleRun(kind: ArticleRunKind.code, text: 'Status')],
        ),
      ],
      rows: const [
        [
          InstalledTableCell(
            cellId: 'c2',
            text: 'tables',
            runs: [ArticleRun(kind: ArticleRunKind.plain, text: 'tables')],
          ),
          InstalledTableCell(
            cellId: 'c3',
            text: 'ok',
            runs: [ArticleRun(kind: ArticleRunKind.plain, text: 'ok')],
          ),
        ],
      ],
      translationById: const {'c0': '特性', 'c1': '状态', 'c2': '表格', 'c3': '正常'},
    ),
    const InstalledCodeBlock(
      blockId: 'cb',
      order: 1,
      language: 'python',
      code: 'def f():\n    return 1\n',
    ),
    const InstalledDividerBlock(blockId: 'db', order: 2),
  ];

  // Built in setUp: testWidgets bodies run under FakeAsync, where the real
  // IO futures inside newTestDependencies (temp dirs, sqlite) never advance.
  late AppDependencies deps;

  setUp(() async {
    deps = await newTestDependencies();
  });

  Future<void> pumpBlock(
    WidgetTester tester,
    ReadingMode mode,
    InstalledBlock block,
  ) async {
    await tester.pumpWidget(
      wrapTestWidget(
        deps,
        Scaffold(
          body: ListView(
            children: [
              ContentBlockView(
                block: block,
                mode: mode,
                textStyle: const TextStyle(fontSize: 16),
                zhStyle: const TextStyle(fontSize: 14),
                currentSentenceId: null,
                viewKeys: const {},
                onSentenceTap: (_) {},
                onLookup: (_, _) {},
                onTranslate: (_, _) {},
                onSelectionChanged: (_, _) {},
                onZhLongPress: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('enOnly shows originals; table/code/divider all render', (
    tester,
  ) async {
    await pumpBlock(tester, ReadingMode.enOnly, blocks[0]);
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Feature'), findsOneWidget);
    expect(find.text('特性'), findsNothing);

    await pumpBlock(tester, ReadingMode.enOnly, blocks[1]);
    expect(find.textContaining('def f():'), findsOneWidget);
    expect(find.text('python'), findsOneWidget);

    await pumpBlock(tester, ReadingMode.enOnly, blocks[2]);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('bilingual stacks original + translation in the same cell', (
    tester,
  ) async {
    await pumpBlock(tester, ReadingMode.bilingual, blocks[0]);
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Feature'), findsOneWidget);
    expect(find.text('特性'), findsOneWidget);
    expect(find.text('ok'), findsOneWidget);
    expect(find.text('正常'), findsOneWidget);

    await pumpBlock(tester, ReadingMode.bilingual, blocks[1]);
    expect(find.byType(Table), findsNothing);
    expect(find.textContaining('def f():'), findsOneWidget);
    await pumpBlock(tester, ReadingMode.bilingual, blocks[2]);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('zhOnly shows the translated table; code and divider once', (
    tester,
  ) async {
    await pumpBlock(tester, ReadingMode.zhOnly, blocks[0]);
    expect(find.text('特性'), findsOneWidget);
    expect(find.text('Feature'), findsNothing);

    await pumpBlock(tester, ReadingMode.zhOnly, blocks[1]);
    expect(find.textContaining('def f():'), findsOneWidget);
    await pumpBlock(tester, ReadingMode.zhOnly, blocks[2]);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('table cells honor column alignment', (tester) async {
    await pumpBlock(tester, ReadingMode.enOnly, blocks[0]);
    final selectable = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .toList();
    expect(selectable, isNotEmpty);
    // default → start, center → center.
    expect(selectable.first.textAlign, TextAlign.start);
    expect(selectable[1].textAlign, TextAlign.center);
  });

  testWidgets('tapping table/code content never opens the sentence menu', (
    tester,
  ) async {
    _installMixedArticle(deps);
    await tester.pumpWidget(
      wrapTestWidget(deps, ReaderPage(articleId: mixedArticleId)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Feature'));
    await tester.pumpAndSettle();
    expect(find.byType(SentenceMenuSheet), findsNothing);

    await tester.tap(find.textContaining('def f():'));
    await tester.pumpAndSettle();
    expect(find.byType(SentenceMenuSheet), findsNothing);
    expect(deps.playback.state.value.isActive, isFalse);

    // Text sentences keep their menu (regression guard for the dispatch).
    await tester.tap(find.text('A styled heading.'));
    await tester.pumpAndSettle();
    expect(find.byType(SentenceMenuSheet), findsOneWidget);
  });

  testWidgets('sentences inside text blocks still render via SentenceView', (
    tester,
  ) async {
    _installMixedArticle(deps);
    await tester.pumpWidget(
      wrapTestWidget(deps, ReaderPage(articleId: mixedArticleId)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SentenceView), findsOneWidget);
    expect(find.text('A styled heading.'), findsOneWidget);
  });
}

const mixedArticleId = '22222222-2222-4222-8222-222222222222';

void _installMixedArticle(AppDependencies deps) {
  final content = ArticleContent.parse(mixedArticleJson());
  deps.library.commitInstall(
    ValidatedArticleImport.fromV1(
      content: content,
      manifest: ReadpackManifest.parse(mixedManifestJson()),
      manifestJson: '{}',
      attributionJson: '{}',
    ),
  );
}

Map<String, Object?> mixedArticleJson() => <String, Object?>{
  'format': 'readpack-article',
  'format_version': '1.1',
  'required_capabilities': ['markdown-blocks'],
  'article_id': mixedArticleId,
  'revision': 1,
  'title': 'Mixed Reader Article',
  'source': {'display_name': null, 'url': null, 'author': 'Au'},
  'source_sha256': 'a' * 64,
  'structure_sha256': 'b' * 64,
  'blocks': [
    {
      'block_id': 'hb',
      'kind': 'heading',
      'order': 0,
      'level': 2,
      'sentences': [
        {
          'sentence_id': 's1',
          'order': 0,
          'text': 'A styled heading.',
          'translation_zh': '一个带样式的标题。',
          'audio_start_sample': 0,
          'audio_end_sample': 24000,
          'audio_start_ms': 0,
          'audio_end_ms': 1000,
          'runs': [
            {'kind': 'plain', 'text': 'A '},
            {'kind': 'emphasis', 'text': 'styled'},
            {'kind': 'plain', 'text': ' heading.'},
          ],
        },
      ],
    },
    {
      'block_id': 'tb',
      'kind': 'table',
      'order': 1,
      'alignments': ['default', 'center'],
      'header': [
        {
          'cell_id': 'c0',
          'text': 'Feature',
          'runs': [
            {'kind': 'plain', 'text': 'Feature'},
          ],
        },
        {
          'cell_id': 'c1',
          'text': 'Status',
          'runs': [
            {'kind': 'plain', 'text': 'Status'},
          ],
        },
      ],
      'rows': [
        [
          {
            'cell_id': 'c2',
            'text': 'tables',
            'runs': [
              {'kind': 'plain', 'text': 'tables'},
            ],
          },
          {
            'cell_id': 'c3',
            'text': 'ok',
            'runs': [
              {'kind': 'plain', 'text': 'ok'},
            ],
          },
        ],
      ],
      'translation_zh': {'c0': '特性', 'c1': '状态', 'c2': '表格', 'c3': '正常'},
    },
    {
      'block_id': 'cb',
      'kind': 'code',
      'order': 2,
      'language': 'python',
      'code': 'def f():\n    return 1\n',
    },
    {'block_id': 'db', 'kind': 'divider', 'order': 3},
  ],
};

Map<String, Object?> mixedManifestJson() => <String, Object?>{
  'format': 'readpack',
  'format_version': '1.1',
  'required_capabilities': ['markdown-blocks'],
  'package_id': '33333333-3333-4333-8333-333333333333',
  'created_at': '2026-08-14T08:00:00Z',
  'article': {'id': mixedArticleId, 'revision': 1, 'artifact_revision': 1},
  'files': [
    {
      'path': 'article.json',
      'size': 1,
      'sha256': 'c' * 64,
      'media_type': 'application/json',
    },
    {
      'path': 'attribution.json',
      'size': 1,
      'sha256': 'd' * 64,
      'media_type': 'application/json',
    },
    {
      'path': 'audio/article.m4a',
      'size': 1,
      'sha256': 'e' * 64,
      'media_type': 'audio/mp4',
    },
  ],
  'audio': {
    'path': 'audio/article.m4a',
    'codec': 'aac-lc',
    'sample_rate_hz': 24000,
    'channels': 1,
    'duration_ms': 2000,
  },
  'pipeline': {
    'version': '0.1.0',
    'segmenter': 'fixture-segmenter@1',
    'translation': {
      'provider': 'fixture-provider',
      'model': 'fixture-model',
      'thinking': 'enabled',
      'reasoning_effort': 'max',
      'prompt': 'fixture-prompt@v1',
    },
    'tts': {
      'custom_voice_model': 'fixture-custom-voice@r1',
      'base_model': 'fixture-base@r1',
      'voice_profile': 'fixture-voice@1',
      'anchor_sha256': 'f' * 64,
    },
  },
};
