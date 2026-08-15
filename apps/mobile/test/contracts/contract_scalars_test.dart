import 'package:engirdle_mobile/contracts/catalog_v1/catalog.dart';
import 'package:engirdle_mobile/contracts/contract_violation.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

/// Internal scalar/structure checks over minimal in-memory JSON (no ZIP):
/// each test mutates a copy of a known-good document, so failures pin the
/// exact schema rule that regressed.
void main() {
  group('article order matches the array position (README data rules)', () {
    test('accepts positional orders', () {
      final article = ArticleContent.parse(validArticle());
      expect(article.blocks, hasLength(2));
      expect(article.sentencesInOrder.map((s) => s.sentenceId),
          ['s0', 's1', 's2']);
    });

    test('rejects a duplicate sentence order', () {
      final json = validArticle();
      sentence(json, 0, 1)['order'] = 0;
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.blocks[0].sentences[1].order')));
    });

    test('rejects a gapped sentence order', () {
      final json = validArticle();
      sentence(json, 0, 1)['order'] = 2;
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.blocks[0].sentences[1].order')));
    });

    test('rejects a duplicate block order', () {
      final json = validArticle();
      block(json, 1)['order'] = 0;
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.blocks[1].order')));
    });

    test('rejects a shuffled block order', () {
      // A contiguous-but-misplaced set used to pass the old Set-based check.
      final json = validArticle();
      block(json, 0)['order'] = 1;
      block(json, 1)['order'] = 0;
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.blocks[0].order')));
    });
  });

  group('opaqueId', () {
    test('accepts ids containing ".." (the schema pattern allows them)', () {
      final json = validArticle();
      block(json, 0)['block_id'] = 'a..b';
      expect(ArticleContent.parse(json).blocks[0].blockId, 'a..b');
    });
  });

  group('manifest scalar patterns', () {
    test('accepts the baseline manifest', () {
      final manifest = ReadpackManifest.parse(validManifest());
      expect(manifest.pipeline.version, '0.1.0');
    });

    test('required_capabilities accepts up to 8 unique schema tokens', () {
      final json = validManifest()
        ..['format_version'] = '1.1'
        ..['required_capabilities'] = [
          'markdown-blocks',
          'a',
          'b-2',
          'c-three',
          'd4',
          'e-5',
          'f6',
          'g7',
        ];
      expect(ReadpackManifest.parse(json).requiredCapabilities, hasLength(8));
      // Which capabilities a version may declare is cross-file semantics;
      // the parser only enforces the schema array rules.
      expect(ReadpackManifest.parse(validManifest()).requiredCapabilities,
          isEmpty);
      final empty = validManifest()..['required_capabilities'] = [];
      expect(ReadpackManifest.parse(empty).requiredCapabilities, isEmpty);
    });

    test('required_capabilities rejects >8 items, duplicates and bad tokens',
        () {
      final tooMany = validManifest()
        ..['required_capabilities'] = [
          for (var i = 0; i < 9; i++) 'cap-$i',
        ];
      expect(() => ReadpackManifest.parse(tooMany),
          throwsA(violationAt('manifest.required_capabilities')));

      final duplicate = validManifest()
        ..['required_capabilities'] = ['markdown-blocks', 'markdown-blocks'];
      expect(() => ReadpackManifest.parse(duplicate),
          throwsA(violationAt('manifest.required_capabilities[1]')));

      for (final bad in ['Markdown-Blocks', '1st', 'has_underscore', '-dash']) {
        final json = validManifest()..['required_capabilities'] = [bad];
        expect(() => ReadpackManifest.parse(json),
            throwsA(violationAt('manifest.required_capabilities[0]')),
            reason: bad);
      }
    });

    test('pipeline.version must be semanticVersion', () {
      for (final bad in ['0.1', 'v1.0.0', '1.0.0.', '1.0']) {
        final json = validManifest();
        pipeline(json)['version'] = bad;
        expect(() => ReadpackManifest.parse(json),
            throwsA(violationAt('manifest.pipeline.version')),
            reason: bad);
      }
      for (final good in ['1.0.0', '2.3.4-rc.1', '10.20.30+build.5']) {
        final json = validManifest();
        pipeline(json)['version'] = good;
        expect(ReadpackManifest.parse(json).pipeline.version, good,
            reason: good);
      }
    });

    test('revisioned identifiers must be name@revision', () {
      final cases = <String, void Function(Map<String, Object?>)>{
        'manifest.pipeline.segmenter': (json) =>
            pipeline(json)['segmenter'] = 'plain-name',
        'manifest.pipeline.translation.prompt': (json) =>
            translation(json)['prompt'] = 'plain-name',
        'manifest.pipeline.tts.custom_voice_model': (json) =>
            tts(json)['custom_voice_model'] = 'plain-name',
        'manifest.pipeline.tts.base_model': (json) =>
            tts(json)['base_model'] = 'plain-name',
        'manifest.pipeline.tts.voice_profile': (json) =>
            tts(json)['voice_profile'] = 'plain-name',
      };
      for (final entry in cases.entries) {
        final json = validManifest();
        entry.value(json);
        expect(() => ReadpackManifest.parse(json),
            throwsA(violationAt(entry.key)),
            reason: entry.key);
      }
      // Empty name or empty revision also reject (`^.+@[^@]+$`).
      for (final bad in ['@1', 'name@']) {
        final json = validManifest();
        pipeline(json)['segmenter'] = bad;
        expect(() => ReadpackManifest.parse(json),
            throwsA(violationAt('manifest.pipeline.segmenter')),
            reason: bad);
      }
      // maxLength 512 from the schema.
      final tooLong = validManifest();
      pipeline(tooLong)['segmenter'] = '${'n' * 511}@r';
      expect(() => ReadpackManifest.parse(tooLong),
          throwsA(violationAt('manifest.pipeline.segmenter')));
    });

    test('created_at must be a strict RFC 3339 date-time', () {
      for (final bad in [
        '2026-08-07T08:00:00+0800', // offset without colon
        '2026-13-45T99:99:99Z', // impossible calendar values
        '2026-02-30T00:00:00Z', // day does not exist in February
      ]) {
        final json = validManifest()..['created_at'] = bad;
        expect(() => ReadpackManifest.parse(json),
            throwsA(violationAt('manifest.created_at')),
            reason: bad);
      }
      for (final good in [
        '2026-08-07T08:00:00+08:00',
        '2026-08-07T08:00:00.5Z',
        '2026-02-28T23:59:59-05:30',
      ]) {
        final json = validManifest()..['created_at'] = good;
        expect(ReadpackManifest.parse(json).createdAt, good, reason: good);
      }
    });
  });

  group('article v1.1 block union', () {
    test('parses heading/table/code/divider strictly', () {
      final article = ArticleContent.parse(v11Article());
      expect(article.formatVersion, '1.1');
      expect(article.requiredCapabilities, ['markdown-blocks']);
      final blocks = article.blocks;
      expect(blocks, hasLength(5));
      expect(blocks[0], isA<ParsedTextBlock>()
          .having((b) => b.kind, 'kind', ArticleTextKind.heading)
          .having((b) => b.level, 'level', 2));
      expect(blocks[1], isA<ParsedTextBlock>()
          .having((b) => b.kind, 'kind', ArticleTextKind.paragraph));
      final table = blocks[2] as ParsedTableBlock;
      expect(table.alignments, [TableAlignment.inherit, TableAlignment.center]);
      expect(table.header, hasLength(2));
      expect(table.rows.single, hasLength(2));
      expect(table.translationById['c0'], '特性');
      final code = blocks[3] as ParsedCodeBlock;
      expect(code.language, 'python');
      expect(code.code, 'def f():\n    return 1\n');
      expect(blocks[4], isA<ParsedDividerBlock>());
      // Sentence runs concatenate to the sentence text.
      final sentence = (blocks[1] as ParsedTextBlock).sentences.single;
      expect(sentence.runs.map((r) => r.text).join(), sentence.text);
      expect(
          sentence.runs.map((r) => r.kind),
          containsAll([
            ArticleRunKind.plain,
            ArticleRunKind.emphasis,
            ArticleRunKind.code,
          ]));
    });

    test('v1.0 keeps working without runs (single plain run)', () {
      final article = ArticleContent.parse(validArticle());
      final sentence = (article.blocks[0] as ParsedTextBlock).sentences[0];
      expect(sentence.runs, hasLength(1));
      expect(sentence.runs.single.kind, ArticleRunKind.plain);
      expect(sentence.runs.single.text, sentence.text);
    });

    test('v1.0 list/quote blocks need no v1.1 payload (defaults apply)', () {
      // A legacy v1.0 package carries no list_kind/quote_depth; the parser
      // must decode it with the documented defaults instead of rejecting.
      final quoteJson = validArticle();
      block(quoteJson, 1).remove('quote_depth');
      final quote = ArticleContent.parse(quoteJson).blocks[1] as ParsedTextBlock;
      expect(quote.kind, ArticleTextKind.quote);
      expect(quote.quoteDepth, 1);

      final listJson = validArticle();
      block(listJson, 0)['kind'] = 'list_item';
      final item = ArticleContent.parse(listJson).blocks[0] as ParsedTextBlock;
      expect(item.kind, ArticleTextKind.listItem);
      expect(item.listKind, ArticleListKind.bullet);
      expect(item.listDepth, 0);
      expect(item.listOrdinal, isNull);

      // v1.1 still requires the explicit payload.
      final v11 = v11Article();
      block(v11, 1)['kind'] = 'list_item';
      expect(
          () => ArticleContent.parse(v11),
          throwsA(isA<ContractViolation>().having(
              (v) => v.problem, 'problem', contains('list_kind'))));
    });

    test('string length caps count Unicode codepoints, not UTF-16 units', () {
      // 300 emoji are 300 codepoints but 600 UTF-16 units; the 512 cap is
      // in codepoints, matching the JSON Schema semantics.
      final json = validArticle();
      json['title'] = '😀' * 300;
      expect(ArticleContent.parse(json).title, '😀' * 300);
      json['title'] = '😀' * 513;
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.title')));
    });

    test('v1.0 rejects the v1.1 block kinds', () {
      for (final kind in ['heading', 'table', 'code', 'divider']) {
        final json = validArticle();
        block(json, 0)['kind'] = kind;
        expect(() => ArticleContent.parse(json),
            throwsA(isA<ContractViolation>().having(
                (v) => v.problem, 'problem', contains('unknown block kind'))),
            reason: kind);
      }
    });

    test('table rows are required: explicit empty array vs missing key', () {
      // An explicit empty array is a legal header-only table...
      final headerOnly = v11Article();
      final tableIndex =
          (headerOnly['blocks'] as List).indexWhere((b) => b['kind'] == 'table');
      final tableBlock =
          (headerOnly['blocks'] as List)[tableIndex] as Map<String, Object?>;
      tableBlock['rows'] = <Object?>[];
      final parsed = ArticleContent.parse(headerOnly);
      final parsedTable =
          parsed.blocks.firstWhere((b) => b is ParsedTableBlock) as ParsedTableBlock;
      expect(parsedTable.rows, isEmpty);

      // ...but a MISSING rows key violates the wire schema.
      final missing = v11Article();
      ((missing['blocks'] as List)[tableIndex] as Map<String, Object?>)
          .remove('rows');
      expect(
          () => ArticleContent.parse(missing),
          throwsA(isA<ContractViolation>().having(
              (v) => v.problem, 'problem', contains('missing required key'))));
    });

    test('v1.1 rejects an unknown block kind', () {
      final json = v11Article();
      block(json, 0)['kind'] = 'aside';
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.blocks[0].kind')));
    });

    test('v1.1 without markdown-blocks rejects at parse', () {
      final json = v11Article()..['required_capabilities'] = [];
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.required_capabilities')));
    });

    test('v1.0 with declared capabilities rejects at parse', () {
      final json = validArticle()..['required_capabilities'] = ['markdown-blocks'];
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.required_capabilities')));
    });

    test('v1.1 sentence runs must concatenate to the sentence text', () {
      final json = v11Article();
      sentence(json, 1, 0)['runs'] = [
        {'kind': 'plain', 'text': 'wrong'},
      ];
      // Concatenation is a semantic (validator) rule; the parse keeps the
      // runs so the cross-file validator can reject the mismatch.
      final parsed = ArticleContent.parse(json);
      final parsedSentence =
          (parsed.blocks[1] as ParsedTextBlock).sentences.single;
      expect(parsedSentence.runs.single.text, 'wrong');
      expect(parsedSentence.text,
          isNot(parsedSentence.runs.map((r) => r.text).join()));
    });

    test('table rows must match the header width', () {
      final json = v11Article();
      final table = block(json, 2);
      (table['rows']! as List<Object?>).removeLast();
      table['rows'] = [
        [
          {'cell_id': 'c2', 'text': 'only one'},
        ],
      ];
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.blocks[2].rows[0]')));
    });

    test('duplicate table cell ids reject', () {
      final json = v11Article();
      final table = block(json, 2);
      (table['rows']! as List<Object?>)[0] = [
        {'cell_id': 'c0', 'text': 'dupe'},
        {'cell_id': 'c1', 'text': 'ok'},
      ];
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.blocks[2].cell_id')));
    });

    test('code blocks must not carry translation_zh or sentences', () {
      final withTranslation = v11Article();
      block(withTranslation, 3)['translation_zh'] = {'x': 'y'};
      expect(() => ArticleContent.parse(withTranslation),
          throwsA(violationAt('article.blocks[3].translation_zh')));

      final withSentences = v11Article();
      block(withSentences, 3)['sentences'] = [];
      expect(() => ArticleContent.parse(withSentences),
          throwsA(violationAt('article.blocks[3].sentences')));
    });

    test('cell runs must concatenate to the cell text', () {
      final json = v11Article();
      final table = block(json, 2);
      (table['header']! as List<Object?>)[0] = {
        'cell_id': 'c0',
        'text': 'Feature',
        'runs': [
          {'kind': 'plain', 'text': 'nope'},
        ],
      };
      expect(() => ArticleContent.parse(json),
          throwsA(violationAt('article.blocks[2].runs')));
    });
  });

  group('catalog scalar rules', () {
    final origin = Uri.parse('http://192.0.2.10:8766/catalog.json');

    test('rejects an uppercase absolute URL scheme (HTTP://)', () {
      final json = validCatalog('HTTP://192.0.2.10:8766/packages/a.readpack');
      expect(() => Catalog.parse(json, origin: origin),
          throwsA(violationAt('catalog.packages[0].url')));
    });

    test('catalog_version is capped at 9007199254740991', () {
      final atMax = validCatalog('/packages/a.readpack')
        ..['catalog_version'] = 9007199254740991;
      expect(Catalog.parse(atMax, origin: origin).catalogVersion,
          9007199254740991);
      final overMax = validCatalog('/packages/a.readpack')
        ..['catalog_version'] = 9007199254740992;
      expect(() => Catalog.parse(overMax, origin: origin),
          throwsA(violationAt('catalog.catalog_version')));
    });
  });
}

Matcher violationAt(String path) =>
    isA<ContractViolation>().having((v) => v.path, 'path', path);

String sha(String ch) => ch * 64;

Map<String, Object?> runOf(String kind, String text, {String? href}) =>
    <String, Object?>{
      'kind': kind,
      'text': text,
      'href': ?href,
    };

Map<String, Object?> sentenceJson(
  String id,
  int order,
  String text, {
  List<Object?>? runs,
  int startSample = 0,
  int endSample = 24000,
  int startMs = 0,
  int endMs = 1000,
}) =>
    <String, Object?>{
      'sentence_id': id,
      'order': order,
      'text': text,
      'translation_zh': '译文',
      'audio_start_sample': startSample,
      'audio_end_sample': endSample,
      'audio_start_ms': startMs,
      'audio_end_ms': endMs,
      'runs': ?runs,
    };

Map<String, Object?> cellJson(String id, String text) =>
    <String, Object?>{
      'cell_id': id,
      'text': text,
      'runs': [runOf('plain', text)],
    };

/// The v1.1 article shape (mirrors the mixed-markdown fixture): one block of
/// every kind with valid audio boundaries.
Map<String, Object?> v11Article() => <String, Object?>{
      'format': 'readpack-article',
      'format_version': '1.1',
      'required_capabilities': ['markdown-blocks'],
      'article_id': '11111111-1111-4111-8111-111111111111',
      'revision': 1,
      'title': 'Mixed Article',
      'source': <String, Object?>{
        'display_name': null,
        'url': null,
        'author': null,
      },
      'source_sha256': sha('a'),
      'structure_sha256': sha('b'),
      'blocks': <Object?>[
        <String, Object?>{
          'block_id': 'b0',
          'kind': 'heading',
          'order': 0,
          'level': 2,
          'sentences': [
            sentenceJson('s1', 0, 'Mixed heading.', runs: [runOf('plain', 'Mixed heading.')]),
          ],
        },
        <String, Object?>{
          'block_id': 'b1',
          'kind': 'paragraph',
          'order': 1,
          'sentences': [
            sentenceJson(
              's2',
              0,
              'The fixture includes a table and code.',
              startSample: 24000,
              endSample: 48000,
              startMs: 1000,
              endMs: 2000,
              runs: [
                runOf('plain', 'The fixture includes a '),
                runOf('emphasis', 'table'),
                runOf('plain', ' and '),
                runOf('code', 'code'),
                runOf('plain', '.'),
              ],
            ),
          ],
        },
        <String, Object?>{
          'block_id': 'b2',
          'kind': 'table',
          'order': 2,
          'alignments': ['default', 'center'],
          'header': [cellJson('c0', 'Feature'), cellJson('c1', 'Status')],
          'rows': [
            [cellJson('c2', 'tables'), cellJson('c3', 'ok')],
          ],
          'translation_zh': {
            'c0': '特性',
            'c1': '状态',
            'c2': '表格',
            'c3': '正常',
          },
        },
        <String, Object?>{
          'block_id': 'b3',
          'kind': 'code',
          'order': 3,
          'language': 'python',
          'code': 'def f():\n    return 1\n',
        },
        <String, Object?>{
          'block_id': 'b4',
          'kind': 'divider',
          'order': 4,
        },
      ],
    };

Map<String, Object?> v10Paragraph() => <String, Object?>{
      'block_id': 'b0',
      'kind': 'paragraph',
      'order': 0,
      'sentences': <Object?>[
        <String, Object?>{
          'sentence_id': 's0',
          'order': 0,
          'text': 'Hello.',
          'translation_zh': '你好。',
          'audio_start_sample': 0,
          'audio_end_sample': 24000,
          'audio_start_ms': 0,
          'audio_end_ms': 1000,
        },
      ],
    };

Map<String, Object?> validArticle() => <String, Object?>{
      'format': 'readpack-article',
      'format_version': '1.0',
      'article_id': '11111111-1111-4111-8111-111111111111',
      'revision': 1,
      'title': 'Minimal Article',
      'source': <String, Object?>{
        'display_name': null,
        'url': null,
        'author': null,
      },
      'source_sha256': sha('a'),
      'structure_sha256': sha('b'),
      'blocks': <Object?>[
        <String, Object?>{
          'block_id': 'b0',
          'kind': 'paragraph',
          'order': 0,
          'sentences': <Object?>[
            <String, Object?>{'sentence_id': 's0', 'order': 0, 'text': 'Hello.'},
            <String, Object?>{'sentence_id': 's1', 'order': 1, 'text': 'World.'},
          ],
        },
        <String, Object?>{
          'block_id': 'b1',
          'kind': 'quote',
          'order': 1,
          'quote_depth': 1,
          'sentences': <Object?>[
            <String, Object?>{'sentence_id': 's2', 'order': 0, 'text': 'Again.'},
          ],
        },
      ],
    };

Map<String, Object?> validManifest() => <String, Object?>{
      'format': 'readpack',
      'format_version': '1.0',
      'package_id': '22222222-2222-4222-8222-222222222222',
      'created_at': '2026-08-07T08:00:00Z',
      'article': <String, Object?>{
        'id': '11111111-1111-4111-8111-111111111111',
        'revision': 1,
        'artifact_revision': 1,
      },
      'files': <Object?>[
        <String, Object?>{
          'path': 'article.json',
          'size': 1,
          'sha256': sha('c'),
          'media_type': 'application/json',
        },
        <String, Object?>{
          'path': 'attribution.json',
          'size': 1,
          'sha256': sha('d'),
          'media_type': 'application/json',
        },
        <String, Object?>{
          'path': 'audio/article.m4a',
          'size': 1,
          'sha256': sha('e'),
          'media_type': 'audio/mp4',
        },
      ],
      'audio': <String, Object?>{
        'path': 'audio/article.m4a',
        'codec': 'aac-lc',
        'sample_rate_hz': 24000,
        'channels': 1,
        'duration_ms': 1000,
      },
      'pipeline': <String, Object?>{
        'version': '0.1.0',
        'segmenter': 'fixture-segmenter@1',
        'translation': <String, Object?>{
          'provider': 'fixture-provider',
          'model': 'fixture-model',
          'thinking': 'enabled',
          'reasoning_effort': 'max',
          'prompt': 'fixture-prompt@v1',
        },
        'tts': <String, Object?>{
          'custom_voice_model': 'fixture-custom-voice@r1',
          'base_model': 'fixture-base@r1',
          'voice_profile': 'fixture-voice@1',
          'anchor_sha256': sha('f'),
        },
      },
    };

Map<String, Object?> validCatalog(String url) => <String, Object?>{
      'catalog_version': 1,
      'generated_at': '2026-08-07T08:05:00Z',
      'packages': <Object?>[
        <String, Object?>{
          'article_id': '22222222-2222-4222-8222-222222222222',
          'revision': 1,
          'artifact_revision': 1,
          'title': 'Minimal Package',
          'format_version': '1.0',
          'size': 1,
          'sha256': sha('0'),
          'url': url,
        },
      ],
    };

Map<String, Object?> block(Map<String, Object?> article, int i) =>
    (article['blocks']! as List<Object?>)[i]! as Map<String, Object?>;

Map<String, Object?> sentence(Map<String, Object?> article, int b, int s) =>
    (block(article, b)['sentences']! as List<Object?>)[s]!
        as Map<String, Object?>;

Map<String, Object?> pipeline(Map<String, Object?> manifest) =>
    manifest['pipeline']! as Map<String, Object?>;

Map<String, Object?> translation(Map<String, Object?> manifest) =>
    pipeline(manifest)['translation']! as Map<String, Object?>;

Map<String, Object?> tts(Map<String, Object?> manifest) =>
    pipeline(manifest)['tts']! as Map<String, Object?>;
