import 'dart:io';

import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/features/library/domain/article_install.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/manifest.dart';
import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/library/infrastructure/library_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/database/migrations.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/translation_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// v3 → v4: blocks.payload_json and sentences.render_json arrive with
/// explicit defaults; legacy rows decode as plain text blocks with one plain
/// run; vocabulary snapshots are untouched.
void main() {
  late Directory temp;
  late String dbPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('app_db_migration_');
    dbPath = p.join(temp.path, 'app.db');
    final legacy = sqlite3.open(dbPath);
    addTearDown(legacy.close);
    // Replay v0→v3 exactly, then pin the version: opening through
    // AppDatabase must apply only the v3→v4 step on top.
    for (final batch in kMigrations.take(3)) {
      legacy.execute('BEGIN IMMEDIATE');
      for (final statement in batch) {
        legacy.execute(statement);
      }
      legacy.execute('COMMIT');
    }
    legacy.userVersion = 3;
    legacy.execute(
      "INSERT INTO articles (article_id, title, author, source_display_name, "
      "source_url, revision, artifact_revision, package_id, format_version, "
      "duration_ms, audio_codec, sample_rate_hz, channels, size_bytes, sha256, "
      "installed_at, manifest_json, attribution_json) "
      "VALUES ('a1','Legacy','Au','src','http://x',1,0,'pkg','1.0',2000,"
      "'aac-lc',24000,1,4,'abc','2026-01-01T00:00:00Z','{}','{}')",
    );
    legacy.execute(
      "INSERT INTO blocks (article_id, block_id, kind, ord) VALUES "
      "('a1','b1','paragraph',0)",
    );
    legacy.execute(
      "INSERT INTO blocks (article_id, block_id, kind, ord) VALUES "
      "('a1','b2','quote',1)",
    );
    for (var i = 0; i < 2; i++) {
      legacy.execute(
        "INSERT INTO sentences (article_id, block_id, sentence_id, ord, text, "
        "translation_zh, audio_start_ms, audio_end_ms, audio_start_sample, "
        "audio_end_sample) VALUES ('a1',?,?,?,'hello $i','你好 $i',0,1000,0,24000)",
        [i == 0 ? 'b1' : 'b2', 's$i', i],
      );
    }
    legacy.execute(
      "INSERT INTO vocabulary (vocabulary_id, surface, normalized, lemma, "
      "part_of_speech, sense_id, sense_en, sense_zh, source_name, "
      "dictionary_id, dictionary_revision, article_id, revision, sentence_id, "
      "sentence_text, sentence_translation_zh, article_title, created_at) "
      "VALUES ('v1','mend','mend',null,'verb','oewn/mend-v-1','to repair',"
      "'修理','OEWN','dict',1,'a1',1,'s0','Mend it.','修理它。','Legacy',"
      "'2026-08-09T00:00:00Z')",
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'v3 migrates to v4 preserving legacy articles and vocab snapshots',
    () async {
      final appDb = AppDatabase.open(dbPath);
      addTearDown(appDb.close);
      final db = appDb.db;

      expect(db.userVersion, kMigrations.length);
      final blockColumns = db.select("PRAGMA table_info('blocks')");
      final payloadColumn = blockColumns.singleWhere(
        (row) => row['name'] == 'payload_json',
      );
      expect(payloadColumn['notnull'], 1);
      expect(payloadColumn['dflt_value'], "''");
      final sentenceColumns = db.select("PRAGMA table_info('sentences')");
      final renderColumn = sentenceColumns.singleWhere(
        (row) => row['name'] == 'render_json',
      );
      expect(renderColumn['notnull'], 1);
      expect(renderColumn['dflt_value'], "''");

      // Legacy paragraphs/quotes decode as plain text blocks...
      final dao = LibraryDao(db);
      final blocks = dao.getBlocks('a1');
      expect(blocks, hasLength(2));
      final paragraph = blocks[0] as InstalledTextBlock;
      expect(paragraph.kind, ArticleTextKind.paragraph);
      expect(paragraph.sentences, hasLength(1));
      // ...and legacy sentences as a single plain run of the whole text.
      final sentence = paragraph.sentences.single;
      expect(sentence.runs, hasLength(1));
      expect(sentence.runs.single.kind, ArticleRunKind.plain);
      expect(sentence.runs.single.text, sentence.text);
      final quote = blocks[1] as InstalledTextBlock;
      expect(quote.kind, ArticleTextKind.quote);
      expect(quote.quoteDepth, 1);
      expect(dao.getArticle('a1')!.title, 'Legacy');

      // Vocabulary snapshots survive the migration untouched.
      final vocab = db.select(
        'SELECT sense_en, sense_zh, sentence_text '
        'FROM vocabulary WHERE vocabulary_id = ?',
        ['v1'],
      ).single;
      expect(vocab['sense_en'], 'to repair');
      expect(vocab['sense_zh'], '修理');
      expect(vocab['sentence_text'], 'Mend it.');
    },
  );

  test(
    'a v1.1 article installs and reads back through the v4 schema',
    () async {
      final appDb = AppDatabase.open(dbPath);
      addTearDown(appDb.close);
      final dao = LibraryDao(appDb.db);
      final content = ArticleContent.parse(v11ArticleJson());
      dao.installArticle(
        ValidatedArticleImport.fromV1(
          content: content,
          manifest: v11ManifestParsed(),
          manifestJson: '{}',
          attributionJson: '{}',
        ),
        installPackagedTranslation: TranslationDao(
          appDb.db,
        ).installPackagedSetFor,
      );

      final blocks = dao.getBlocks(content.articleId);
      expect(blocks, hasLength(5));
      final heading = blocks[0] as InstalledTextBlock;
      expect(heading.kind, ArticleTextKind.heading);
      expect(heading.level, 2);
      expect(heading.sentences.single.runs, isNotEmpty);
      final listBlock = blocks[1] as InstalledTextBlock;
      expect(listBlock.listKind, ArticleListKind.ordered);
      expect(listBlock.listDepth, 1);
      expect(listBlock.listOrdinal, 3);
      final table = blocks[2] as InstalledTableBlock;
      expect(table.alignments, [TableAlignment.left, TableAlignment.center]);
      expect(table.header.singleWhere((c) => c.cellId == 'c0').text, 'Feature');
      expect(
        table.header.singleWhere((c) => c.cellId == 'c1').runs.single.kind,
        ArticleRunKind.code,
      );
      expect(table.translationById['c0'], '特性');
      final code = blocks[3] as InstalledCodeBlock;
      expect(code.language, 'python');
      expect(code.code, 'def f():\n    return 1\n');
      expect(blocks[4], isA<InstalledDividerBlock>());
      // Sentence runs round-trip through render_json.
      final runs = (blocks[0] as InstalledTextBlock).sentences.single.runs;
      expect(runs.map((r) => r.kind).toList(), [
        ArticleRunKind.plain,
        ArticleRunKind.emphasis,
        ArticleRunKind.plain,
      ]);
      expect(runs.map((r) => r.text).join(), 'A styled heading.');
    },
  );
}

Map<String, Object?> v11ArticleJson() => <String, Object?>{
  'format': 'readpack-article',
  'format_version': '1.1',
  'required_capabilities': ['markdown-blocks'],
  'article_id': '22222222-2222-4222-8222-222222222222',
  'revision': 1,
  'title': 'Mixed',
  'source': {'display_name': null, 'url': null, 'author': null},
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
      'block_id': 'lb',
      'kind': 'list_item',
      'order': 1,
      'list_kind': 'ordered',
      'list_depth': 1,
      'list_ordinal': 3,
      'sentences': [
        {
          'sentence_id': 's2',
          'order': 0,
          'text': 'One item.',
          'translation_zh': '一条目。',
          'audio_start_sample': 24000,
          'audio_end_sample': 48000,
          'audio_start_ms': 1000,
          'audio_end_ms': 2000,
          'runs': [
            {'kind': 'plain', 'text': 'One item.'},
          ],
        },
      ],
    },
    {
      'block_id': 'tb',
      'kind': 'table',
      'order': 2,
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
    },
    {
      'block_id': 'cb',
      'kind': 'code',
      'order': 3,
      'language': 'python',
      'code': 'def f():\n    return 1\n',
    },
    {'block_id': 'db', 'kind': 'divider', 'order': 4},
  ],
};

Map<String, Object?> v11ManifestJson() => <String, Object?>{
  'format': 'readpack',
  'format_version': '1.1',
  'required_capabilities': ['markdown-blocks'],
  'package_id': '33333333-3333-4333-8333-333333333333',
  'created_at': '2026-08-14T08:00:00Z',
  'article': {
    'id': '22222222-2222-4222-8222-222222222222',
    'revision': 1,
    'artifact_revision': 1,
  },
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

ReadpackManifest v11ManifestParsed() =>
    ReadpackManifest.parse(v11ManifestJson());
