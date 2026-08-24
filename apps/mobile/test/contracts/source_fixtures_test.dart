import 'dart:convert';
import 'dart:io';

import 'package:engirdle_mobile/features/source_ingestion/domain/source_parse_error.dart';
import 'package:engirdle_mobile/features/source_ingestion/infrastructure/markdown_parser.dart';
import 'package:engirdle_mobile/features/source_ingestion/infrastructure/structure_hash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Dart-side consumption of the shared source-parsing gold fixtures
/// (contracts/source/v1): the same corpus the PC test
/// (apps/pc/tests/contract/source/test_source_fixtures.py) proves against
/// `engirdle-gfm@1`. The Dart parser must reproduce the frozen projection —
/// blocks, sentences, runs, warnings and all three hashes — byte-for-byte.
void main() {
  final fixtures = Directory(
    p.join(
      Directory.current.path,
      '..',
      '..',
      'contracts',
      'source',
      'v1',
      'fixtures',
    ),
  );
  final expectedDir = Directory(p.join(fixtures.path, 'expected'));

  Map<String, Object?> projectionOf(File input) {
    final raw = input.readAsStringSync();
    final parsed = parseMarkdownSource(raw);
    return {
      'source_sha256': sha256OfText(raw),
      'normalized_sha256': sha256OfText(parsed.canonical),
      'structure_sha256': structureSha256Of(parsed.blocks),
      'warnings': [
        for (final w in parsed.warnings)
          {'code': w.code, 'block_index': w.blockIndex},
      ],
      'blocks': [for (final block in parsed.blocks) blockPayload(block)],
    };
  }

  test('fixture corpus is present', () {
    expect(fixtures.listSync().whereType<File>().length, greaterThan(10));
  });

  for (final input in fixtures.listSync().whereType<File>()) {
    if (!input.path.endsWith('.md')) continue;
    final expectedFile = File(
      p.join(
        expectedDir.path,
        '${p.basenameWithoutExtension(input.path)}.json',
      ),
    );
    test('${p.basename(input.path)} matches the frozen expectation', () {
      final expected =
          jsonDecode(expectedFile.readAsStringSync()) as Map<String, Object?>;
      final actual = projectionOf(input);
      expect(actual['source_sha256'], expected['source_sha256']);
      expect(actual['normalized_sha256'], expected['normalized_sha256']);
      expect(actual['structure_sha256'], expected['structure_sha256']);
      expect(
        (actual['warnings'] as List).map((w) => (w as Map)['code']),
        (expected['warnings'] as List).map((w) => (w as Map)['code']),
      );
      // The full projection equality subsumes the hashes above; assert both
      // so a failure points at the specific drift.
      expect(actual['blocks'], expected['blocks']);
    });
  }

  // Both platforms reject the frozen reject corpus (mobile codes map the PC
  // UnsupportedMarkdown type; see contracts/source/v1 README).
  for (final input in Directory(
    p.join(fixtures.path, 'reject'),
  ).listSync().whereType<File>()) {
    if (!input.path.endsWith('.md')) continue;
    final stem = p.basenameWithoutExtension(input.path);
    test('reject/$stem.md is rejected', () {
      final code = switch (stem) {
        'empty' => 'empty_body',
        _ => 'raw_html',
      };
      expect(
        () => parseMarkdownSource(input.readAsStringSync()),
        throwsA(
          isA<SourceParseException>().having((e) => e.code, 'code', code),
        ),
      );
    });
  }
}
