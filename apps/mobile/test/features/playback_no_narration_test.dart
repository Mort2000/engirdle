import 'dart:io';

import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/manifest.dart';
import 'package:engirdle_mobile/features/library/application/library_service.dart';
import 'package:engirdle_mobile/features/library/domain/article_install.dart';
import 'package:engirdle_mobile/features/library/infrastructure/library_dao.dart';
import 'package:engirdle_mobile/features/playback/domain/lease_registry.dart';
import 'package:engirdle_mobile/features/playback/infrastructure/library_playback_source_adapter.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:engirdle_mobile/shared_kernel/content_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Table and code blocks are never narratable: they bear no sentences, so
/// they can never produce a playback range — defense in depth behind the
/// reader's absent play affordances on those blocks.
void main() {
  late Directory temp;
  late AppDatabase appDb;
  late LibraryService library;
  late LeaseRegistry registry;
  late ArticleRef ref;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('playback_no_narration_');
    final dirs = AppDirectories(temp);
    await dirs.ensureBaseLayout();
    appDb = AppDatabase.inMemory();
    registry = LeaseRegistry();
    library = LibraryService(
      dao: LibraryDao(appDb.db),
      directories: dirs,
      playbackLeases: registry,
    );
    ref = ArticleRef(articleId: articleId, revision: 1, artifactRevision: 1);
  });

  tearDown(() async {
    appDb.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  void install({required bool withSentence}) {
    // The audio file only needs to exist for actual playback, not for
    // resolving ranges; keep the artifact layout honest anyway.
    final audio = File(
      p.join(library.artifactDirectory(ref).path, 'audio', 'article.m4a'),
    );
    audio.createSync(recursive: true);
    library.commitInstall(
      ValidatedArticleImport.fromV1(
        content: ArticleContent.parse(articleJson(withSentence: withSentence)),
        manifest: ReadpackManifest.parse(manifestJson()),
        manifestJson: '{}',
        attributionJson: '{}',
      ),
    );
  }

  test(
    'an article of only table/code/divider blocks has no narration lease',
    () async {
      install(withSentence: false);
      final adapter = LibraryPlaybackSourceAdapter(
        library: library,
        registry: registry,
      );

      // Zero narratable sentences means no narration asset at all: acquire
      // fails clearly instead of leasing an audio file with empty ranges.
      await expectLater(
        adapter.acquire(ref),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('playback.source.no_narration'),
          ),
        ),
      );
      expect(registry.isLeasedArticle(articleId), isFalse);
    },
  );

  test('a mixed article counts only narratable sentences', () async {
    install(withSentence: true);
    final adapter = LibraryPlaybackSourceAdapter(
      library: library,
      registry: registry,
    );

    final lease = await adapter.acquire(ref);
    expect(lease.ranges, hasLength(1));
    expect(lease.ranges.single.sentenceId, 's1');
    expect(lease.ranges.single.label, '第 1 段第 1 句');
    adapter.release(lease);
  });
}

const articleId = '44444444-4444-4444-8444-444444444444';

Map<String, Object?> articleJson({required bool withSentence}) =>
    <String, Object?>{
      'format': 'readpack-article',
      'format_version': '1.1',
      'required_capabilities': ['markdown-blocks'],
      'article_id': articleId,
      'revision': 1,
      'title': 'Playback guard',
      'source': {'display_name': null, 'url': null, 'author': null},
      'source_sha256': 'a' * 64,
      'structure_sha256': 'b' * 64,
      'blocks': [
        if (withSentence)
          {
            'block_id': 'hb',
            'kind': 'heading',
            'order': 0,
            'level': 1,
            'sentences': [
              {
                'sentence_id': 's1',
                'order': 0,
                'text': 'Narratable.',
                'translation_zh': '可朗读。',
                'audio_start_sample': 0,
                'audio_end_sample': 24000,
                'audio_start_ms': 0,
                'audio_end_ms': 1000,
                'runs': [
                  {'kind': 'plain', 'text': 'Narratable.'},
                ],
              },
            ],
          }
        else
          {
            'block_id': 'tb',
            'kind': 'table',
            'order': 0,
            'alignments': ['left'],
            'header': [
              {
                'cell_id': 'c0',
                'text': 'x',
                'runs': [
                  {'kind': 'plain', 'text': 'x'},
                ],
              },
            ],
            'rows': <Object?>[],
            'translation_zh': {'c0': '叉'},
          },
        {
          'block_id': 'cb',
          'kind': 'code',
          'order': 1,
          'language': 'bash',
          'code': 'echo hi',
        },
        {'block_id': 'db', 'kind': 'divider', 'order': 2},
      ],
    };

Map<String, Object?> manifestJson() => <String, Object?>{
  'format': 'readpack',
  'format_version': '1.1',
  'required_capabilities': ['markdown-blocks'],
  'package_id': '55555555-5555-4555-8555-555555555555',
  'created_at': '2026-08-14T08:00:00Z',
  'article': {'id': articleId, 'revision': 1, 'artifact_revision': 1},
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
