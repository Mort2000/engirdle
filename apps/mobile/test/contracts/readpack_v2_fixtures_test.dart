import 'dart:convert';
import 'dart:io';

import 'package:engirdle_mobile/contracts/contract_violation.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/manifest.dart';
import 'package:engirdle_mobile/contracts/readpack_v2/readpack_v2_validator.dart';
import 'package:engirdle_mobile/features/importer/application/readpack_router.dart';
import 'package:engirdle_mobile/platform/crypto/sha256.dart';
import 'package:engirdle_mobile/platform/zip/secure_zip_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Flutter-side consumption of the shared Readpack v2 fixtures
/// (contracts/README.md: a contract change ships both apps' tests in the
/// same change). Since the phase-2 validator shipped, this exercises the
/// production ReadpackV2Validator and the v1/v2 router directly; JSON
/// Schema conformance stays PC-side (contracts/readpack/v2 README).
void main() {
  final fixtures = Directory(
    p.join(
      Directory.current.path,
      '..',
      '..',
      'contracts',
      'readpack',
      'v2',
      'fixtures',
    ),
  );

  Future<Map<String, File>> extract(File zip) async {
    final temp = await Directory.systemTemp.createTemp('v2_fixture_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    const reader = SecureZipReader();
    final entries = await reader.preflight(zip);
    final files = <String, File>{};
    for (final entry in entries) {
      final out = File(p.join(temp.path, entry.path));
      await reader.extractEntry(zip, entry, out);
      files[entry.path] = out;
    }
    return files;
  }

  const validator = ReadpackV2Validator();
  const router = ReadpackRouter();

  for (final (name, translation, narration) in [
    ('source-only.readpack', false, false),
    ('translated.readpack', true, false),
    ('narrated.readpack', false, true),
    ('full.readpack', true, true),
  ]) {
    test(
      'valid/$name validates and projects onto the unified install',
      () async {
        final files = await extract(File(p.join(fixtures.path, 'valid', name)));
        final validated = await validator.validate(
          files,
          sha256Of: sha256OfFile,
        );

        expect(validated.manifest.formatVersion, '2.0');
        expect(validated.manifest.requiredCapabilities, isEmpty);
        expect(validated.translations.isNotEmpty, translation);
        expect(validated.narration != null, narration);

        final install = await router.validate(
          files,
          sha256Of: sha256OfFile,
          origin: 'document',
        );
        expect(install.origin, 'document');
        expect(install.formatVersion, '2.0');
        expect(install.sourceSyntax, 'markdown');
        expect(install.parserVersion, isNotNull);
        expect(install.segmenterVersion, 'engirdle-segmenter@3');
        expect(install.translation != null, translation);
        expect(install.narration != null, narration);
        expect(install.blocks, isNotEmpty);
        if (narration) {
          expect(install.narration!.audioPath, 'audio/article.m4a');
        }
      },
    );
  }

  test('duplicate-path is rejected by the safe ZIP reader itself', () async {
    final zip = File(
      p.join(fixtures.path, 'invalid', 'duplicate-path.readpack'),
    );
    await expectLater(
      const SecureZipReader().preflight(zip),
      throwsA(anything),
    );
  });

  test('a v1 client rejects the v2 major before any layout check', () async {
    final files = await extract(
      File(p.join(fixtures.path, 'valid', 'source-only.readpack')),
    );
    final decoded = await files['manifest.json']!.readAsString();
    expect(
      () => ReadpackManifest.parse(jsonDecode(decoded)),
      throwsA(isA<ContractViolation>()),
    );
    // And the router reports the unsupported major for anything not 1.x/2.x.
    files['manifest.json']!.writeAsStringSync(
      decoded.replaceFirst(
        '"format_version": "2.0"',
        '"format_version": "9.0"',
      ),
    );
    await expectLater(
      router.validate(files, sha256Of: sha256OfFile, origin: 'document'),
      throwsA(
        isA<ContractViolation>().having(
          (e) => e.toString(),
          'reason',
          contains('9.0'),
        ),
      ),
    );
  });

  for (final (name, reason) in [
    ('undeclared-extra-file.readpack', 'undeclared'),
    ('missing-base-file.readpack', 'missing'),
    ('unsupported-major.readpack', 'major'),
    ('unknown-capability.readpack', 'required_capabilities'),
    ('wrong-hash.readpack', 'sha256 mismatch'),
    ('translation-sentence-missing.readpack', 'expected'),
    ('translation-structure-mismatch.readpack', 'structure hash'),
    ('translation-cell-missing.readpack', 'cells'),
    ('narration-range-empty.readpack', 'range'),
    ('audio-without-narration.readpack', 'narration'),
  ]) {
    test('invalid/$name fails for: $reason', () async {
      final files = await extract(File(p.join(fixtures.path, 'invalid', name)));
      await expectLater(
        validator.validate(files, sha256Of: sha256OfFile),
        throwsA(
          isA<ContractViolation>().having(
            (e) => e.toString(),
            'reason',
            contains(reason),
          ),
        ),
      );
    });
  }
}
