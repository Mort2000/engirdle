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

/// Rewrites every v2 document's `format_version` in an extracted package and
/// repairs the manifest's size/hash declarations, yielding a structurally
/// sound package in the given version (forward-minor cases the frozen
/// fixtures cannot express).
Future<Map<String, File>> withVersion(
  Map<String, File> files, {
  required String to,
}) async {
  final manifestFile = files['manifest.json']!;
  final manifest =
      jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
  final declared = (manifest['files']! as List<Object?>)
      .cast<Map<String, Object?>>();
  for (final path in files.keys.toList()) {
    if (path == 'manifest.json' || !path.endsWith('.json')) continue;
    final file = files[path]!;
    final text = (await file.readAsString()).replaceAllMapped(
      RegExp(r'"(format_version)":\s*"2\.\d+"'),
      (m) => '"${m.group(1)}": "$to"',
    );
    await file.writeAsString(text);
    final entry = declared.firstWhere((f) => f['path'] == path);
    entry['size'] = file.lengthSync();
    entry['sha256'] = await sha256OfFile(file);
  }
  manifest['format_version'] = to;
  await manifestFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(manifest),
  );
  return files;
}

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

  test('a same-major newer minor validates (compatibility rule)', () async {
    // contracts/README.md: an implementation accepts every minor of its own
    // major — newer minors only add ignorable fields, which the Dart readers
    // skip by construction. Required capabilities remain the refusal gate.
    final files = await extract(
      File(p.join(fixtures.path, 'valid', 'full.readpack')),
    );
    await withVersion(files, to: '2.3');
    final validated = await validator.validate(files, sha256Of: sha256OfFile);
    expect(validated.manifest.formatVersion, '2.3');
    expect(validated.translations, isNotEmpty);
    expect(validated.narration, isNotNull);
  });

  test(
    'a declared file outside the fixed layout rejects even when present',
    () async {
      // The typed allow-list mirrors the schema's files[].oneOf: a manifest
      // that declares — and a ZIP that really contains — notes.txt must fail
      // the layout, not pass because the path sets happen to agree.
      final files = await extract(
        File(p.join(fixtures.path, 'valid', 'source-only.readpack')),
      );
      final manifestFile = files['manifest.json']!;
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
      final notes = File(p.join(p.dirname(manifestFile.path), 'notes.txt'));
      await notes.writeAsString('producer notes');
      (manifest['files']! as List<Object?>).add({
        'path': 'notes.txt',
        'size': notes.lengthSync(),
        'sha256': await sha256OfFile(notes),
        'media_type': 'text/plain',
      });
      await manifestFile.writeAsString(jsonEncode(manifest));
      files['notes.txt'] = notes;

      await expectLater(
        validator.validate(files, sha256Of: sha256OfFile),
        throwsA(
          isA<ContractViolation>().having(
            (e) => e.toString(),
            'reason',
            contains('not part of the v2 fixed layout'),
          ),
        ),
      );
    },
  );

  test('a known path with the wrong media type rejects', () async {
    final files = await extract(
      File(p.join(fixtures.path, 'valid', 'source-only.readpack')),
    );
    final manifestFile = files['manifest.json']!;
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
    ((manifest['files']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .firstWhere((f) => f['path'] == 'article.json'))['media_type'] =
        'text/plain';
    await manifestFile.writeAsString(jsonEncode(manifest));

    await expectLater(
      validator.validate(files, sha256Of: sha256OfFile),
      throwsA(
        isA<ContractViolation>().having(
          (e) => e.toString(),
          'reason',
          contains('expected "application/json"'),
        ),
      ),
    );
  });

  test(
    'the router installs only the zh-Hans derivative and ignores others',
    () async {
      // Design §2.2/§5.3: mobile 首期只认识 zh-Hans. A package whose
      // translation derivative carries another locale must never feed that
      // text into the zh projection.
      final files = await extract(
        File(p.join(fixtures.path, 'valid', 'translated.readpack')),
      );
      // Re-label the descriptor AND the derivative as fr-FR (structure stays
      // valid; only the locale moves).
      final manifestFile = files['manifest.json']!;
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
      final derivatives = manifest['derivatives']! as Map<String, Object?>;
      final descriptor = (derivatives['translations']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .single;
      final frPath = 'derivatives/translation.fr-FR.json';
      final frFile = File(
        p.join(p.dirname(manifestFile.path), 'translation.fr-FR.json'),
      );
      await frFile.writeAsString(
        (await files['derivatives/translation.zh-Hans.json']!.readAsString())
            .replaceAll('zh-Hans', 'fr-FR'),
      );
      files.remove('derivatives/translation.zh-Hans.json');
      files[frPath] = frFile;
      descriptor['locale'] = 'fr-FR';
      descriptor['path'] = frPath;
      final entries = (manifest['files']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final translationEntry = entries.firstWhere(
        (f) => (f['path'] as String).startsWith('derivatives/translation.'),
      );
      translationEntry['path'] = frPath;
      translationEntry['size'] = frFile.lengthSync();
      translationEntry['sha256'] = await sha256OfFile(frFile);
      await manifestFile.writeAsString(jsonEncode(manifest));

      final install = await router.validate(
        files,
        sha256Of: sha256OfFile,
        origin: 'document',
      );
      expect(install.translation, isNull);
      expect(install.narration, isNull);
      expect(install.blocks, isNotEmpty);
    },
  );
}
