import 'dart:convert';
import 'dart:io';

import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/library/infrastructure/library_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/database/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// v4 → v5: base/derivative split (lightweight-readpack design §11). Legacy
/// v1 articles keep reading identically: packaged translations become a
/// complete active TranslationSet, audio columns become a NarrationAsset,
/// and the sentence/table base carries no derived data.
void main() {
  late Directory temp;
  late String dbPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('app_db_v5_migration_');
    dbPath = p.join(temp.path, 'app.db');
    final legacy = sqlite3.open(dbPath);
    addTearDown(legacy.close);
    for (final batch in kMigrations.take(4)) {
      legacy.execute('BEGIN IMMEDIATE');
      for (final statement in batch) {
        legacy.execute(statement);
      }
      legacy.execute('COMMIT');
    }
    legacy.userVersion = 4;

    legacy.execute(
      "INSERT INTO articles (article_id, title, author, source_display_name, "
      "source_url, revision, artifact_revision, package_id, format_version, "
      "duration_ms, audio_codec, sample_rate_hz, channels, size_bytes, sha256, "
      "installed_at, manifest_json, attribution_json) "
      "VALUES ('a1','Mixed','Au','src','http://x',1,1,'pkg','1.1',2000,"
      "'aac-lc',24000,1,4,'${'a' * 64}','2026-01-01T00:00:00Z',"
      "'${jsonEncode(_manifestJson())}','{}')",
    );
    legacy.execute(
      "INSERT INTO blocks (article_id, block_id, kind, ord, payload_json) "
      "VALUES ('a1','b1','heading',0,'{\"level\":2}')",
    );
    legacy.execute(
      "INSERT INTO blocks (article_id, block_id, kind, ord, payload_json) "
      "VALUES ('a1','b2','table',1,'${jsonEncode(_tablePayload())}')",
    );
    legacy.execute(
      "INSERT INTO sentences (article_id, block_id, sentence_id, ord, text, "
      "translation_zh, audio_start_ms, audio_end_ms, audio_start_sample, "
      "audio_end_sample, render_json) VALUES "
      "('a1','b1','s1',0,'Heading one.','标题一。',0,500,0,12000,"
      "'[{\"kind\":\"plain\",\"text\":\"Heading one.\"}]')",
    );
    legacy.execute(
      "INSERT INTO sentences (article_id, block_id, sentence_id, ord, text, "
      "translation_zh, audio_start_ms, audio_end_ms, audio_start_sample, "
      "audio_end_sample, render_json) VALUES "
      "('a1','b2','s2',0,'No audio row.',NULL,NULL,NULL,NULL,NULL,"
      "'[{\"kind\":\"plain\",\"text\":\"No audio row.\"}]')",
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'v4 migrates to v5 splitting base, translation set and narration',
    () async {
      final appDb = AppDatabase.open(dbPath);
      addTearDown(appDb.close);
      final db = appDb.db;

      expect(db.userVersion, 5);

      // Base row: identity + pipeline versions, no audio columns.
      final article = db
          .select(
            'SELECT * FROM articles WHERE article_id = '
            "'a1'",
          )
          .single;
      final articleColumns = db.select("PRAGMA table_info('articles')");
      expect(
        articleColumns.map((row) => row['name']),
        isNot(anyOf(contains('duration_ms'), contains('audio_codec'))),
      );
      expect(article['origin'], 'catalog');
      expect(article['current_artifact_revision'], 1);
      expect(article['parser_version'], 'fixture-parser@1');
      expect(article['segmenter_version'], 'fixture-segmenter@2');
      // Pre-v5 installs never stored the article hashes; they stay unknown.
      expect(article['source_sha256'], isNull);
      expect(article['structure_sha256'], isNull);

      // Artifact row takes over the package-level columns verbatim.
      final artifact = db
          .select(
            'SELECT * FROM article_artifacts '
            "WHERE article_id = 'a1' AND artifact_revision = 1",
          )
          .single;
      expect(artifact['ingress_kind'], 'catalog');
      expect(artifact['package_id'], 'pkg');
      expect(artifact['format_version'], '1.1');
      expect(artifact['sha256'], 'a' * 64);

      // Packaged translations become one complete active zh-Hans set.
      final set = db
          .select("SELECT * FROM translation_sets WHERE article_id = 'a1'")
          .single;
      expect(set['origin'], 'packaged');
      expect(set['status'], 'complete');
      expect(set['target_locale'], 'zh-Hans');
      final pipeline =
          jsonDecode(set['pipeline_json'] as String) as Map<String, Object?>;
      expect(pipeline['provider'], 'fixture-provider');
      expect(pipeline['prompt'], 'fixture-prompt@v1');
      final sentenceTranslations = db.select(
        'SELECT sentence_id, text FROM sentence_translations '
        'WHERE translation_set_id = ?',
        [set['translation_set_id']],
      );
      expect(
        {
          for (final row in sentenceTranslations)
            row['sentence_id']: row['text'],
        },
        {'s1': '标题一。'},
      );
      final cellTranslations = db.select(
        'SELECT block_id, cell_id, text FROM table_cell_translations '
        'WHERE translation_set_id = ?',
        [set['translation_set_id']],
      );
      expect(
        {
          for (final row in cellTranslations)
            '${row['block_id']}/${row['cell_id']}': row['text'],
        },
        {'b2/c0': '特性', 'b2/c1': '状态', 'b2/c2': '表格', 'b2/c3': '正常'},
      );
      final active = db
          .select(
            "SELECT * FROM article_active_translations WHERE article_id = 'a1'",
          )
          .single;
      expect(active['translation_set_id'], set['translation_set_id']);
      expect(active['target_locale'], 'zh-Hans');

      // Audio columns become one narration asset with per-sentence ranges.
      final narration = db
          .select("SELECT * FROM narration_assets WHERE article_id = 'a1'")
          .single;
      expect(narration['codec'], 'aac-lc');
      expect(narration['sample_rate_hz'], 24000);
      expect(narration['duration_ms'], 2000);
      final ranges = db.select(
        'SELECT sentence_id, audio_start_ms, audio_end_ms '
        'FROM sentence_audio_ranges WHERE narration_id = ?',
        [narration['narration_id']],
      );
      expect(ranges, hasLength(1));
      expect(ranges.first['sentence_id'], 's1');
      expect(ranges.first['audio_start_ms'], 0);

      // The sentence base carries no derived columns, and table payloads no
      // longer embed translations.
      final sentenceColumns = db.select("PRAGMA table_info('sentences')");
      expect(
        sentenceColumns.map((row) => row['name']),
        isNot(anyOf(contains('translation_zh'), contains('audio_start_ms'))),
      );
      final tablePayload =
          db
                  .select(
                    "SELECT payload_json FROM blocks WHERE block_id = 'b2'",
                  )
                  .single['payload_json']
              as String;
      expect(jsonDecode(tablePayload), isNot(contains('translation_zh')));
      expect(
        (jsonDecode(tablePayload) as Map<String, Object?>)['header'],
        isNotNull,
      );
    },
  );

  test(
    'reading a migrated article composes the same reader projection',
    () async {
      final appDb = AppDatabase.open(dbPath);
      addTearDown(appDb.close);
      final dao = LibraryDao(appDb.db);

      final article = dao.getArticle('a1')!;
      expect(article.title, 'Mixed');
      expect(article.narration?.durationMs, 2000);
      expect(article.narration?.codec, 'aac-lc');

      final blocks = dao.getBlocks('a1');
      final heading = blocks[0] as InstalledTextBlock;
      final sentence = heading.sentences.single;
      expect(sentence.translationZh, '标题一。');
      expect(sentence.hasAudio, isTrue);
      expect(sentence.audioStartMs, 0);
      expect(sentence.audioEndMs, 500);
      final table = blocks[1] as InstalledTableBlock;
      expect(table.translationById['c0'], '特性');
      expect(table.translationById['c3'], '正常');
      final plainRow = (blocks[0] as InstalledTextBlock).sentences;
      expect(dao.getBlocks('a1')[1], isA<InstalledTableBlock>());
      expect(plainRow, isNotEmpty);
    },
  );
}

Map<String, Object?> _manifestJson() => <String, Object?>{
  'format': 'readpack',
  'format_version': '1.1',
  'package_id': '33333333-3333-4333-8333-333333333333',
  'created_at': '2026-08-14T08:00:00Z',
  'article': {'id': 'a1', 'revision': 1, 'artifact_revision': 1},
  'files': [
    {
      'path': 'article.json',
      'size': 1,
      'sha256': 'b' * 64,
      'media_type': 'application/json',
    },
    {
      'path': 'attribution.json',
      'size': 1,
      'sha256': 'c' * 64,
      'media_type': 'application/json',
    },
    {
      'path': 'audio/article.m4a',
      'size': 1,
      'sha256': 'd' * 64,
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
    'parser': 'fixture-parser@1',
    'segmenter': 'fixture-segmenter@2',
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

Map<String, Object?> _tablePayload() => <String, Object?>{
  'alignments': ['left', 'center'],
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
        {'kind': 'code', 'text': 'Status'},
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
};
