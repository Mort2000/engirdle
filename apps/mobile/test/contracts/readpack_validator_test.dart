import 'package:engirdle_mobile/contracts/contract_violation.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/shared_kernel/failures.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

/// Contract fixtures from contracts/readpack/v1/fixtures. Each invalid
/// package must be rejected for the documented first-failure reason
/// (fixtures/README.md).
void main() {
  group('readpack v1 fixtures', () {
    test('valid/minimal.readpack is accepted', () async {
      final validated =
          await extractAndValidate(readpackFixture('valid/minimal.readpack'));
      expect(validated.manifest.formatVersion, startsWith('1.'));
      expect(validated.manifest.audio.codec, 'aac-lc');
      expect(validated.article.blocks, isNotEmpty);
      expect(validated.article.sentencesInOrder, isNotEmpty);
      expect(validated.attribution.resources.length, greaterThanOrEqualTo(7));
      // One article identity across all three documents.
      expect(validated.article.articleId, validated.manifest.articleId);
      expect(validated.attribution.articleId, validated.manifest.articleId);
      expect(validated.article.revision, validated.manifest.revision);
      // Exact envelope facts from the fixture.
      expect(validated.manifest.audio.durationMs, 1000);
      expect(validated.manifest.files, hasLength(3));
    });

    test('valid/mixed-markdown.readpack (v1.1) is accepted', () async {
      final validated =
          await extractAndValidate(readpackFixture('valid/mixed-markdown.readpack'));
      expect(validated.manifest.formatVersion, '1.1');
      expect(validated.manifest.requiredCapabilities, ['markdown-blocks']);
      expect(validated.article.formatVersion, '1.1');
      expect(validated.article.requiredCapabilities, ['markdown-blocks']);
      final blocks = validated.article.blocks;
      expect(blocks.map((b) => b.runtimeType.toString()), [
        'ParsedTextBlock',
        'ParsedTextBlock',
        'ParsedTableBlock',
        'ParsedCodeBlock',
        'ParsedDividerBlock',
      ]);
      final heading = blocks[0] as ParsedTextBlock;
      expect(heading.kind, ArticleTextKind.heading);
      expect(heading.level, 2);
      final table = blocks[2] as ParsedTableBlock;
      expect(table.translationById.keys, unorderedEquals({'cell-3-0', 'cell-3-1', 'cell-3-2', 'cell-3-3'}));
      final code = blocks[3] as ParsedCodeBlock;
      expect(code.language, 'python');
      expect(code.code, startsWith('def fixture():'));
      // Sentences (only the narratable text blocks) carry non-empty runs.
      for (final sentence in validated.article.sentencesInOrder) {
        expect(sentence.runs, isNotEmpty);
        expect(sentence.runs.map((r) => r.text).join(), sentence.text);
      }
    });

    test('valid/v10-legacy-list-quote.readpack is accepted with defaults', () async {
      // A legacy v1.0 package: list_item without list_kind and quote without
      // quote_depth decode to the documented defaults (COMPATIBILITY.md).
      final validated = await extractAndValidate(
          readpackFixture('valid/v10-legacy-list-quote.readpack'));
      expect(validated.manifest.formatVersion, '1.0');
      expect(validated.manifest.requiredCapabilities, isEmpty);
      final blocks = validated.article.blocks;
      expect(blocks, hasLength(2));
      final item = blocks[0] as ParsedTextBlock;
      expect(item.kind, ArticleTextKind.listItem);
      expect(item.listKind, ArticleListKind.bullet);
      expect(item.listDepth, 0);
      final quote = blocks[1] as ParsedTextBlock;
      expect(quote.kind, ArticleTextKind.quote);
      expect(quote.quoteDepth, 1);
    });

    // Rejected by the cross-file validator (ContractViolation).
    final contractViolations = <String, Pattern>{
      'invalid/missing-file.readpack': 'missing file',
      'invalid/wrong-hash.readpack': 'sha256 mismatch',
      'invalid/unsupported-major.readpack': 'unsupported major version',
      'invalid/invalid-article-schema.readpack': 'unknown block kind',
      'invalid/invalid-attribution-schema.readpack': 'unknown status',
      'invalid/missing-translation.readpack': 'missing translation',
      'invalid/invalid-audio-range.readpack': 'empty sample range',
      'invalid/article-id-mismatch.readpack': 'mismatch with manifest',
      // v1.1 markdown-blocks semantics (COMPATIBILITY.md).
      'invalid/unknown-capability.readpack':
          'markdown_capability_unsupported',
      'invalid/table-translation-shape.readpack': 'cell identity set',
      'invalid/code-with-translation.readpack':
          'must not carry the "translation_zh" payload',
      'invalid/empty-runs.readpack': 'non-empty runs',
      'invalid/duplicate-cell-id.readpack': 'duplicate table cell id',
      'invalid/no-narration.readpack': 'at least one narratable sentence',
      'invalid/v10-with-markdown-blocks.readpack': 'unknown block kind',
      'invalid/divider-with-sentences.readpack':
          'must not carry the "sentences" payload',
    };
    for (final entry in contractViolations.entries) {
      test('${entry.key} is rejected as a contract violation', () async {
        await expectLater(
          extractAndValidate(readpackFixture(entry.key)),
          throwsA(isA<ContractViolation>().having(
              (v) => v.problem, 'problem', contains(entry.value as String))),
        );
      });
    }

    // Rejected by the secure ZIP reader before/while touching the payload
    // (AppFailure: packageFormat or resourceLimit).
    final packageFailures = <String, Pattern>{
      'invalid/duplicate-path.readpack': 'duplicate path',
      'invalid/path-traversal.readpack': 'unsafe path',
      'invalid/oversized-entry.readpack': 'entry too large',
    };
    for (final entry in packageFailures.entries) {
      test('${entry.key} is rejected as a package failure', () async {
        await expectLater(
          extractAndValidate(readpackFixture(entry.key)),
          throwsA(isA<AppFailure>().having(
              (f) => f.message, 'message', contains(entry.value as String))),
        );
      });
    }

    test('oversized-entry is rejected by preflight before any extraction',
        () async {
      // The declared size lives only in the central directory; preflight must
      // refuse before reading entry data.
      await expectLater(
        extractAndValidate(readpackFixture('invalid/oversized-entry.readpack')),
        throwsA(isA<AppFailure>()
            .having((f) => f.kind, 'kind', FailureKind.resourceLimit)),
      );
    });
  });
}
