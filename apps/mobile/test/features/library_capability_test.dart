import 'dart:convert';
import 'dart:io';

import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/manifest.dart';
import 'package:engirdle_mobile/features/library/application/library_service.dart';
import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/library/infrastructure/library_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:engirdle_mobile/shared_kernel/failures.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase-1 capability split: installs write base + packaged translation set
/// + narration asset separately, reading composes them back, and the active
/// translation pointer switches atomically (lightweight-readpack design §4).
void main() {
  late Directory temp;
  late AppDatabase appDb;
  late LibraryService library;
  late LibraryDao dao;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('library_capability_');
    await AppDirectories(temp).ensureBaseLayout();
    appDb = AppDatabase.inMemory();
    addTearDown(appDb.close);
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    dao = LibraryDao(appDb.db);
    library = LibraryService(dao: dao, directories: AppDirectories(temp));
  });

  InstalledContent install(Object? articleJson) {
    final manifestJson = _manifestJson();
    final content = ArticleContent.parse(articleJson);
    library.commitInstall(
      content: content,
      manifest: ReadpackManifest.parse(jsonDecode(manifestJson)),
      manifestJson: manifestJson,
      attributionJson: '{}',
    );
    return library.getContent(content.articleId)!;
  }

  test('a complete v1.1 install reads back translated and narrated', () {
    final content = install(_translatedArticle());

    expect(content.capabilities.hasTranslation, isTrue);
    expect(content.capabilities.hasNarration, isTrue);
    expect(content.audioFilePath, isNotNull);
    final block = content.blocks.single as InstalledTextBlock;
    expect(block.sentences.single.translationZh, '你好。');
    expect(block.sentences.single.hasAudio, isTrue);
    expect(content.article.narration?.durationMs, 1000);
  });

  test('an article without derivatives has neither capability', () {
    final content = install(_sourceOnlyArticle());

    expect(content.capabilities.hasTranslation, isFalse);
    expect(content.capabilities.hasNarration, isFalse);
    expect(content.audioFilePath, isNull);
    expect(content.article.narration, isNull);
    final sentence =
        (content.blocks.single as InstalledTextBlock).sentences.single;
    expect(sentence.translationZh, isNull);
    expect(sentence.hasAudio, isFalse);
    // No fake derivative rows exist anywhere.
    final db = appDb.db;
    expect(
      db.select('SELECT COUNT(*) AS n FROM translation_sets').first['n'],
      0,
    );
    expect(
      db.select('SELECT COUNT(*) AS n FROM narration_assets').first['n'],
      0,
    );
  });

  test('switching the active translation set is atomic and exact', () {
    final content = install(_translatedArticle());
    final articleId = content.article.articleId;
    final db = appDb.db;
    db.execute(
      "INSERT INTO translation_sets (translation_set_id, article_id, "
      'artifact_revision, structure_sha256, target_locale, origin, status, '
      "pipeline_json, created_at) VALUES ('set-2', ?, 1, ?, 'zh-Hans', "
      "'device', 'complete', NULL, '2026-01-02T00:00:00Z')",
      [articleId, content.article.structureSha256],
    );
    db.execute(
      "INSERT INTO sentence_translations (translation_set_id, sentence_id, "
      "text) VALUES ('set-2', 's1', '第二套译文。')",
    );

    library.activateTranslation(articleId, 'set-2');

    final switched = library.getContent(articleId)!;
    expect(
      (switched.blocks.single as InstalledTextBlock)
          .sentences
          .single
          .translationZh,
      '第二套译文。',
    );

    // A set with incomplete coverage must never become active.
    db.execute(
      "INSERT INTO translation_sets (translation_set_id, article_id, "
      'artifact_revision, structure_sha256, target_locale, origin, status, '
      "pipeline_json, created_at) VALUES ('set-3', ?, 1, ?, 'zh-Hans', "
      "'device', 'complete', NULL, '2026-01-02T00:00:00Z')",
      [articleId, content.article.structureSha256],
    );
    expect(
      () => library.activateTranslation(articleId, 'set-3'),
      throwsA(isA<AppFailure>()),
    );
    // The previous activation survives the rejection.
    expect(
      (library.getContent(articleId)!.blocks.single as InstalledTextBlock)
          .sentences
          .single
          .translationZh,
      '第二套译文。',
    );
  });

  test('deleting the article removes sets, narration and the pointer', () {
    final content = install(_translatedArticle());
    final articleId = content.article.articleId;
    final db = appDb.db;

    library.deleteArticle(articleId).ignore();
    // deleteArticle is async for the file part; the DB rows go first.
    expect(db.select('SELECT COUNT(*) AS n FROM articles').first['n'], 0);
    expect(
      db.select('SELECT COUNT(*) AS n FROM translation_sets').first['n'],
      0,
    );
    expect(
      db.select('SELECT COUNT(*) AS n FROM narration_assets').first['n'],
      0,
    );
    expect(
      db
          .select('SELECT COUNT(*) AS n FROM article_active_translations')
          .first['n'],
      0,
    );
  });
}

String _manifestJson() =>
    '{"format":"readpack","format_version":"1.1",'
    '"required_capabilities":["markdown-blocks"],'
    '"package_id":"33333333-3333-4333-8333-333333333333",'
    '"created_at":"2026-08-24T08:00:00Z",'
    '"article":{"id":"11111111-1111-4111-8111-111111111111",'
    '"revision":1,"artifact_revision":1},'
    '"files":[{"path":"article.json","size":1,"sha256":"${'a' * 64}",'
    '"media_type":"application/json"},'
    '{"path":"attribution.json","size":1,"sha256":"${'b' * 64}",'
    '"media_type":"application/json"},'
    '{"path":"audio/article.m4a","size":1,"sha256":"${'c' * 64}",'
    '"media_type":"audio/mp4"}],'
    '"audio":{"path":"audio/article.m4a","codec":"aac-lc",'
    '"sample_rate_hz":24000,"channels":1,"duration_ms":1000},'
    '"pipeline":{"version":"0.1.0","segmenter":"seg@1",'
    '"translation":{"provider":"p","model":"m","thinking":"enabled",'
    '"reasoning_effort":"max","prompt":"pr@1"},'
    '"tts":{"custom_voice_model":"c@1","base_model":"b@1",'
    '"voice_profile":"v@1","anchor_sha256":"${'d' * 64}"}}}';

Map<String, Object?> _translatedArticle() => <String, Object?>{
  'format': 'readpack-article',
  'format_version': '1.1',
  'required_capabilities': ['markdown-blocks'],
  'article_id': '11111111-1111-4111-8111-111111111111',
  'revision': 1,
  'title': 'Translated',
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
          'text': 'Hello.',
          'translation_zh': '你好。',
          'audio_start_sample': 0,
          'audio_end_sample': 24000,
          'audio_start_ms': 0,
          'audio_end_ms': 1000,
          'runs': [
            {'kind': 'plain', 'text': 'Hello.'},
          ],
        },
      ],
    },
  ],
};

Map<String, Object?> _sourceOnlyArticle() => <String, Object?>{
  'format': 'readpack-article',
  'format_version': '1.1',
  'required_capabilities': ['markdown-blocks'],
  'article_id': '11111111-1111-4111-8111-111111111111',
  'revision': 1,
  'title': 'Source only',
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
          'text': 'Hello.',
          'runs': [
            {'kind': 'plain', 'text': 'Hello.'},
          ],
        },
      ],
    },
  ],
};
