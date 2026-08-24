import 'dart:convert';

import 'package:engirdle_mobile/app/dependencies.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/manifest.dart';
import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/reader/presentation/reader_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

/// Capability gating in the reader (lightweight-readpack design §12.3):
/// an article without derivatives offers only en-only reading (hidden, not
/// disabled), hides sentence playback affordances, and safely falls back
/// from a persisted bilingual preference without rewriting it.
void main() {
  // Built in setUp: testWidgets bodies run under FakeAsync, where the real
  // IO futures inside newTestDependencies (temp dirs, sqlite) never advance.
  late AppDependencies deps;

  setUp(() async {
    deps = await newTestDependencies();
  });

  testWidgets('a source-only article reads en-only with no play affordances', (
    tester,
  ) async {
    deps.library.commitInstall(
      content: ArticleContent.parse(_articleJson(translated: false)),
      manifest: ReadpackManifest.parse(jsonDecode(_manifestJson())),
      manifestJson: _manifestJson(),
      attributionJson: '{}',
    );

    await tester.pumpWidget(
      wrapTestWidget(deps, const ReaderPage(articleId: _articleId)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hello source.'), findsOneWidget);
    // Meta line degrades to 仅原文 instead of a fake narration duration.
    expect(find.textContaining('仅原文'), findsOneWidget);

    // Mode chip offers only en-only.
    await tester.tap(find.byType(PopupMenuButton<ReadingMode>));
    await tester.pumpAndSettle();
    expect(find.text('仅英文'), findsOneWidget);
    expect(find.text('英中对照'), findsNothing);
    expect(find.text('仅中文'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // Sentence menu: no translation drawer row, no play rows.
    await tester.tap(find.text('Hello source.'));
    await tester.pumpAndSettle();
    expect(find.text('单句翻译'), findsNothing);
    expect(find.text('单句朗读'), findsNothing);
    expect(find.text('从此开始朗读'), findsNothing);
  });

  testWidgets('a translated article still offers all reading modes', (
    tester,
  ) async {
    deps.library.commitInstall(
      content: ArticleContent.parse(_articleJson(translated: true)),
      manifest: ReadpackManifest.parse(jsonDecode(_manifestJson())),
      manifestJson: _manifestJson(),
      attributionJson: '{}',
    );

    await tester.pumpWidget(
      wrapTestWidget(deps, const ReaderPage(articleId: _articleId)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<ReadingMode>));
    await tester.pumpAndSettle();
    expect(find.text('仅英文'), findsOneWidget);
    expect(find.text('英中对照'), findsOneWidget);
    expect(find.text('仅中文'), findsOneWidget);
  });

  testWidgets('a persisted bilingual preference falls back safely', (
    tester,
  ) async {
    deps.library.commitInstall(
      content: ArticleContent.parse(_articleJson(translated: false)),
      manifest: ReadpackManifest.parse(jsonDecode(_manifestJson())),
      manifestJson: _manifestJson(),
      attributionJson: '{}',
    );
    deps.library.setReadingMode(_articleId, ReadingMode.bilingual);

    await tester.pumpWidget(
      wrapTestWidget(deps, const ReaderPage(articleId: _articleId)),
    );
    await tester.pumpAndSettle();

    // English text renders (en-only fallback), not an empty zh pane.
    expect(find.text('Hello source.'), findsOneWidget);
    // The stored preference survives for a future translation set.
    expect(deps.library.readingMode(_articleId), ReadingMode.bilingual);
  });
}

const _articleId = '44444444-4444-4444-8444-444444444444';

Map<String, Object?> _articleJson({required bool translated}) =>
    <String, Object?>{
      'format': 'readpack-article',
      'format_version': '1.1',
      'required_capabilities': ['markdown-blocks'],
      'article_id': _articleId,
      'revision': 1,
      'title': 'Capability gate',
      'source': {'display_name': null, 'url': null, 'author': null},
      'source_sha256': 'a' * 64,
      'structure_sha256': 'b' * 64,
      'blocks': [
        {
          'block_id': 'b1',
          'kind': 'paragraph',
          'order': 0,
          'sentences': [
            {
              'sentence_id': 's1',
              'order': 0,
              'text': 'Hello source.',
              if (translated) 'translation_zh': '你好，原文。',
              if (translated) 'audio_start_sample': 0,
              if (translated) 'audio_end_sample': 24000,
              if (translated) 'audio_start_ms': 0,
              if (translated) 'audio_end_ms': 1000,
              'runs': [
                {'kind': 'plain', 'text': 'Hello source.'},
              ],
            },
          ],
        },
      ],
    };

String _manifestJson() => jsonEncode(<String, Object?>{
  'format': 'readpack',
  'format_version': '1.1',
  'required_capabilities': ['markdown-blocks'],
  'package_id': '33333333-3333-4333-8333-333333333333',
  'created_at': '2026-08-24T08:00:00Z',
  'article': {'id': _articleId, 'revision': 1, 'artifact_revision': 1},
  'files': [
    {
      'path': 'article.json',
      'size': 1,
      'sha256': 'a' * 64,
      'media_type': 'application/json',
    },
    {
      'path': 'attribution.json',
      'size': 1,
      'sha256': 'b' * 64,
      'media_type': 'application/json',
    },
    {
      'path': 'audio/article.m4a',
      'size': 1,
      'sha256': 'c' * 64,
      'media_type': 'audio/mp4',
    },
  ],
  'audio': {
    'path': 'audio/article.m4a',
    'codec': 'aac-lc',
    'sample_rate_hz': 24000,
    'channels': 1,
    'duration_ms': 1000,
  },
  'pipeline': {
    'version': '0.1.0',
    'segmenter': 'seg@1',
    'translation': {
      'provider': 'p',
      'model': 'm',
      'thinking': 'enabled',
      'reasoning_effort': 'max',
      'prompt': 'pr@1',
    },
    'tts': {
      'custom_voice_model': 'c@1',
      'base_model': 'b@1',
      'voice_profile': 'v@1',
      'anchor_sha256': 'd' * 64,
    },
  },
});
