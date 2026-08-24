import 'dart:convert';
import 'dart:io';

import 'package:engirdle_mobile/contracts/contract_violation.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/manifest.dart';
import 'package:engirdle_mobile/platform/crypto/sha256.dart';
import 'package:engirdle_mobile/platform/zip/secure_zip_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Flutter-side consumption of the shared Readpack v2 fixtures
/// (contracts/README.md: a contract change ships both apps' tests in the
/// same change). This is the container/semantic seed of the phase-2 mobile
/// v2 validator: schema conformance stays PC-side until the validator ships.
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

  Future<Object?> readJson(File file) async =>
      jsonDecode(await file.readAsString());

  group('readpack v2 valid fixtures', () {
    for (final name in [
      'source-only.readpack',
      'translated.readpack',
      'narrated.readpack',
      'full.readpack',
    ]) {
      test('valid/$name passes structural validation', () async {
        final files = await extract(File(p.join(fixtures.path, 'valid', name)));

        final manifest =
            await readJson(files['manifest.json']!) as Map<String, Object?>;
        expect(manifest['format_version'] as String, startsWith('2.'));
        expect(manifest['required_capabilities'] as List<Object?>?, isEmpty);

        // Exact path-set equality: manifest declares every payload but
        // itself, and the ZIP carries nothing undeclared.
        final declared = {
          for (final entry in manifest['files'] as List<Object?>)
            (entry as Map<String, Object?>)['path'] as String,
        };
        expect(files.keys.toSet(), {...declared, 'manifest.json'});

        // Integrity: byte size and SHA-256 per declared payload.
        for (final entry in manifest['files'] as List<Object?>) {
          final descriptor = entry as Map<String, Object?>;
          final file = files[descriptor['path']]!;
          expect(await file.length(), descriptor['size']);
          expect(await sha256OfFile(file), descriptor['sha256']);
        }

        // Derivative presence matrix follows the manifest descriptors.
        final derivatives = manifest['derivatives'] as Map<String, Object?>;
        final translations =
            derivatives['translations'] as List<Object?>? ?? const [];
        final narration = derivatives['narration'] as Map<String, Object?>?;
        expect(
          files.containsKey('derivatives/translation.zh-Hans.json'),
          translations.isNotEmpty,
        );
        expect(
          files.containsKey('derivatives/narration.json'),
          narration != null,
        );
        expect(files.containsKey('audio/article.m4a'), narration != null);

        // Semantic core: text sentence coverage binds base to derivatives.
        final article =
            await readJson(files['article.json']!) as Map<String, Object?>;
        final sentenceIds = [
          for (final block in article['blocks'] as List<Object?>)
            if ((block as Map<String, Object?>).containsKey('sentences'))
              for (final sentence in block['sentences'] as List<Object?>)
                (sentence as Map<String, Object?>)['sentence_id'] as String,
        ];
        if (translations.isNotEmpty) {
          final translation =
              await readJson(files['derivatives/translation.zh-Hans.json']!)
                  as Map<String, Object?>;
          expect(translation['structure_sha256'], article['structure_sha256']);
          expect([
            for (final item in translation['sentences'] as List<Object?>)
              (item as Map<String, Object?>)['sentence_id'],
          ], sentenceIds);
        }
        if (narration != null) {
          final narrationPayload =
              await readJson(files['derivatives/narration.json']!)
                  as Map<String, Object?>;
          expect(
            narrationPayload['structure_sha256'],
            article['structure_sha256'],
          );
          final ranges = narrationPayload['sentences'] as List<Object?>;
          expect([
            for (final item in ranges)
              (item as Map<String, Object?>)['sentence_id'],
          ], sentenceIds);
        }
      });
    }
  });

  group('readpack v2 invalid fixtures', () {
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
      final manifestJson = await readJson(files['manifest.json']!);
      expect(
        () => ReadpackManifest.parse(manifestJson),
        throwsA(isA<ContractViolation>()),
      );
    });

    for (final (name, reason) in [
      ('undeclared-extra-file.readpack', 'undeclared file'),
      ('missing-base-file.readpack', 'missing declared file'),
      ('unsupported-major.readpack', 'major version'),
      ('unknown-capability.readpack', 'required_capabilities'),
      ('wrong-hash.readpack', 'hash'),
      ('translation-sentence-missing.readpack', 'sentence coverage'),
      ('translation-structure-mismatch.readpack', 'structure hash'),
      ('translation-cell-missing.readpack', 'cell coverage'),
      ('narration-range-empty.readpack', 'empty narration range'),
      ('audio-without-narration.readpack', 'narration derivative'),
    ]) {
      test('invalid/$name fails for: $reason', () async {
        final files = await extract(
          File(p.join(fixtures.path, 'invalid', name)),
        );
        final reasonFound = await _firstFailure(files, readJson, sha256OfFile);
        expect(reasonFound, contains(reason));
      });
    }
  });
}

/// The documented first failure of an invalid package (fixtures/README.md):
/// a compact walk mirroring the reading order — envelope, container set,
/// integrity, capabilities, derivative binding. Kept in sync with the
/// PC-side checker; full JSON Schema conformance is PC-side.
Future<String> _firstFailure(
  Map<String, File> files,
  Future<Object?> Function(File) readJson,
  Future<String> Function(File) shaOfFile,
) async {
  final manifest =
      await readJson(files['manifest.json']!) as Map<String, Object?>;
  final version = manifest['format_version'] as String;
  if (!version.startsWith('2.')) {
    return 'unsupported major version $version';
  }
  final capabilities = manifest['required_capabilities'] as List<Object?>?;
  if (capabilities != null && capabilities.isNotEmpty) {
    return 'v2.0 defines no required_capabilities';
  }
  final declared = {
    for (final entry in manifest['files'] as List<Object?>)
      (entry as Map<String, Object?>)['path'] as String,
  };
  final undeclared = files.keys.toSet().difference({
    ...declared,
    'manifest.json',
  });
  if (undeclared.isNotEmpty) {
    return 'undeclared file(s): $undeclared';
  }
  final missing = declared.difference(
    files.keys.toSet().difference({'manifest.json'}),
  );
  if (missing.isNotEmpty) {
    return 'missing declared file(s): $missing';
  }
  for (final entry in manifest['files'] as List<Object?>) {
    final descriptor = entry as Map<String, Object?>;
    final file = files[descriptor['path'] as String]!;
    if (await file.length() != descriptor['size'] ||
        await shaOfFile(file) != descriptor['sha256']) {
      return '${descriptor['path']}: size or hash mismatch';
    }
  }
  final derivatives = manifest['derivatives'] as Map<String, Object?>;
  final narration = derivatives['narration'] as Map<String, Object?>?;
  final audioDeclared = declared.contains('audio/article.m4a');
  if (audioDeclared && narration == null) {
    return 'audio file declared without a narration derivative';
  }
  final article =
      await readJson(files['article.json']!) as Map<String, Object?>;
  final sentenceIds = [
    for (final block in article['blocks'] as List<Object?>)
      if ((block as Map<String, Object?>).containsKey('sentences'))
        for (final sentence in block['sentences'] as List<Object?>)
          (sentence as Map<String, Object?>)['sentence_id'] as String,
  ];
  final translations =
      derivatives['translations'] as List<Object?>? ?? const [];
  if (translations.isNotEmpty) {
    final translation =
        await readJson(files['derivatives/translation.zh-Hans.json']!)
            as Map<String, Object?>;
    if (translation['structure_sha256'] != article['structure_sha256']) {
      return 'translation binds a different structure hash';
    }
    final translated = [
      for (final item in translation['sentences'] as List<Object?>)
        (item as Map<String, Object?>)['sentence_id'] as String,
    ];
    if (!_sameSet(translated, sentenceIds)) {
      return 'translation sentence coverage mismatch';
    }
    final tableBlocks = <Map<String, Object?>>[
      for (final block in article['blocks'] as List<Object?>)
        if ((block as Map<String, Object?>)['kind'] == 'table') block,
    ];
    for (final table in translation['tables'] as List<Object?>) {
      final entry = table as Map<String, Object?>;
      final baseBlock = tableBlocks.firstWhere(
        (block) => block['block_id'] == entry['block_id'],
      );
      final baseCellIds = <String>[
        for (final cellRow in [
          ...baseBlock['header'] as List<Object?>,
          ...(baseBlock['rows'] as List<Object?>).expand(
            (row) => row as List<Object?>,
          ),
        ])
          (cellRow as Map<String, Object?>)['cell_id'] as String,
      ];
      final translatedCellIds = [
        for (final cell in entry['cells'] as List<Object?>)
          (cell as Map<String, Object?>)['cell_id'] as String,
      ];
      if (!_sameSet(translatedCellIds, baseCellIds)) {
        return 'translation cell coverage mismatch';
      }
    }
  }
  if (narration != null) {
    final narrationPayload =
        await readJson(files['derivatives/narration.json']!)
            as Map<String, Object?>;
    for (final item in narrationPayload['sentences'] as List<Object?>) {
      final range = item as Map<String, Object?>;
      if ((range['audio_start_sample'] as int) >=
          (range['audio_end_sample'] as int)) {
        return '${range['sentence_id']}: empty narration range';
      }
    }
  }
  return 'no failure found';
}

bool _sameSet(List<String> a, List<String> b) =>
    a.length == b.length && {...a}.containsAll(b);
