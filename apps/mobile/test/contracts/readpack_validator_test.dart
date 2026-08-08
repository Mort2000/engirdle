import 'package:engirdle_mobile/contracts/contract_violation.dart';
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
