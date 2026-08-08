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

    test('rejects a non-empty required_capabilities', () {
      final json = validManifest()..['required_capabilities'] = ['new-tms'];
      expect(() => ReadpackManifest.parse(json),
          throwsA(violationAt('manifest.required_capabilities')));
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
