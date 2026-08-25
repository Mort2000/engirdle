import 'dart:convert';
import 'dart:io';

import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/translation/application/protected_tokens.dart';
import 'package:engirdle_mobile/features/translation/application/response_validation.dart';
import 'package:engirdle_mobile/features/translation/application/translation_plan.dart';
import 'package:engirdle_mobile/features/translation/application/translation_protocol.dart';
import 'package:engirdle_mobile/features/translation/domain/translation_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Dart-side consumption of the shared translation-v1 contract
/// (contracts/translation/v1): the same frozen artifacts the PC test
/// (apps/pc/tests/contract/translation/test_translation_contract.py) proves
/// against the Python implementation. The Dart implementation must reproduce
/// every artifact byte for byte and accept/reject the shared response
/// fixtures exactly as documented — protocol drift surfaces here, in both
/// CI suites, not in wrong translations.
void main() {
  final contractDir = Directory(
    p.normalize(
      p.join(Directory.current.path, '..', '..', 'contracts', 'translation'),
    ),
  );

  String fixture(String relative) =>
      File(p.join(contractDir.path, 'v1', relative)).readAsStringSync();

  late Map<String, Object?> protocol;
  late List<InstalledBlock> goldenBlocks;
  late String goldenTitle;
  late String? goldenAuthor;

  setUpAll(() {
    protocol = jsonDecode(fixture('protocol.json')) as Map<String, Object?>;
    final golden =
        jsonDecode(fixture('fixtures/golden/article.json'))
            as Map<String, Object?>;
    goldenTitle = golden['title']! as String;
    goldenAuthor = golden['author']! as String?;
    goldenBlocks = [
      for (final (i, raw) in (golden['blocks']! as List).indexed)
        _blockFromJson(i, raw! as Map<String, Object?>),
    ];
  });

  TranslationPlanUnit unitOf(String blockId) => buildTranslationPlan(
    goldenBlocks,
  ).units.firstWhere((u) => u.blockId == blockId);

  group('protocol constants match the frozen contract', () {
    test('prompt version, thinking, effort, locale and length cap', () {
      expect(kTranslationPromptVersion, protocol['prompt_version']);
      expect(kTranslationThinkingMode, protocol['thinking_mode']);
      expect(kTranslationReasoningEffort, protocol['reasoning_effort']);
      expect(kTranslationTargetLocale, protocol['target_locale']);
      expect(kMaxTranslationChars, protocol['max_translation_chars']);
    });

    test('system prompt is byte-for-byte the frozen text', () {
      final frozen = File(
        p.join(contractDir.path, 'v1', 'system_prompt.txt'),
      ).readAsStringSync();
      expect(kTranslationSystemPrompt, frozen);
    });
  });

  group('golden article projects to the frozen messages', () {
    late Map<String, Object?> expected;

    setUpAll(() {
      expected =
          jsonDecode(fixture('fixtures/golden/expected_messages.json'))
              as Map<String, Object?>;
    });

    test('source context matches byte for byte', () {
      final actual = buildSourceContext(
        title: goldenTitle,
        author: goldenAuthor,
        blocks: goldenBlocks,
      );
      expect(actual, expected['source_context']);
    });

    test('unit requests match byte for byte, in article order', () {
      final units = buildTranslationPlan(goldenBlocks).units;
      final requests = [for (final unit in units) buildUnitRequest(unit)];
      expect(requests, expected['unit_requests']);
      expect(kTranslationSystemPrompt, expected['system']);
    });

    test('code bodies and hrefs never enter any request', () {
      final everything = [
        buildSourceContext(
          title: goldenTitle,
          author: goldenAuthor,
          blocks: goldenBlocks,
        ),
        for (final unit in buildTranslationPlan(goldenBlocks).units)
          buildUnitRequest(unit),
      ].join('\n');
      expect(everything.contains('def fixture'), isFalse);
      expect(everything.contains('python'), isFalse);
      expect(everything.contains('engirdle.example'), isFalse);
      expect(everything.contains('source text'), isFalse); // inline code
    });
  });

  group('response fixtures', () {
    test('valid sentence array passes and restores', () {
      final accepted = validateUnitResponse(
        content: fixture('fixtures/responses/valid/sentence-array.json'),
        unit: unitOf('block-1'),
      );
      expect(accepted, isA<SentenceUnitTranslation>());
      final sentence = accepted as SentenceUnitTranslation;
      expect(sentence.translations, hasLength(1));
      expect(sentence.translations.first.text, isNotEmpty);
    });

    test('valid fenced sentence reply equals the plain reply', () {
      final plain = validateUnitResponse(
        content: fixture('fixtures/responses/valid/sentence-array.json'),
        unit: unitOf('block-1'),
      );
      final fenced = validateUnitResponse(
        content: fixture('fixtures/responses/valid/sentence-fenced.txt'),
        unit: unitOf('block-1'),
      );
      expect(
        (fenced as SentenceUnitTranslation).translations.first.text,
        (plain as SentenceUnitTranslation).translations.first.text,
      );
    });

    test('valid table object passes with placeholders restored', () {
      final accepted = validateUnitResponse(
        content: fixture('fixtures/responses/valid/table-object.json'),
        unit: unitOf('block-3'),
      );
      final table = accepted as TableUnitTranslation;
      expect(table.cells, hasLength(4));
      // cell-3-3's wire text was the ‰0‰ placeholder for the code literal
      // "article.json"; it must come back as the literal itself.
      final codeCell = table.cells.firstWhere((c) => c.cellId == 'cell-3-3');
      expect(codeCell.text, contains('article.json'));
      expect(codeCell.text.contains(kPlaceholderSentinel), isFalse);
    });

    for (final (fixturePath, blockId) in [
      ('fixtures/responses/invalid/sentence-wrong-length.json', 'block-1'),
      ('fixtures/responses/invalid/sentence-empty-item.json', 'block-1'),
      ('fixtures/responses/invalid/prose-wrapped.txt', 'block-1'),
      ('fixtures/responses/invalid/table-cell-added.json', 'block-3'),
      ('fixtures/responses/invalid/table-damaged-placeholder.txt', 'block-3'),
    ]) {
      test('$fixturePath is rejected', () {
        expect(
          () => validateUnitResponse(
            content: fixture(fixturePath),
            unit: unitOf(blockId),
          ),
          throwsA(isA<TranslationProtocolError>()),
        );
      });
    }
  });
}

InstalledBlock _blockFromJson(int order, Map<String, Object?> json) {
  final blockId = json['block_id']! as String;
  switch (json['kind']!) {
    case 'heading':
      return InstalledTextBlock(
        blockId: blockId,
        order: order,
        kind: ArticleTextKind.heading,
        level: json['level']! as int,
        sentences: _sentences(json),
      );
    case 'paragraph':
      return InstalledTextBlock(
        blockId: blockId,
        order: order,
        kind: ArticleTextKind.paragraph,
        sentences: _sentences(json),
      );
    case 'table':
      return InstalledTableBlock(
        blockId: blockId,
        order: order,
        alignments: [
          for (final a in json['alignments']! as List)
            TableAlignmentWire.fromWire(a! as String) ?? TableAlignment.inherit,
        ],
        header: [
          for (final c in json['header']! as List)
            _cell(c! as Map<String, Object?>),
        ],
        rows: [
          for (final row in json['rows']! as List)
            [
              for (final c in row! as List)
                _cell(c! as Map<String, Object?>),
            ],
        ],
        translationById: const {},
      );
    case 'code':
      return InstalledCodeBlock(
        blockId: blockId,
        order: order,
        language: json['language'] as String?,
        code: json['code']! as String,
      );
    case 'divider':
      return InstalledDividerBlock(blockId: blockId, order: order);
    default:
      throw StateError('unknown golden block kind ${json['kind']}');
  }
}

List<InstalledSentence> _sentences(Map<String, Object?> json) => [
  for (final raw in json['sentences']! as List)
    () {
      final s = raw! as Map<String, Object?>;
      return InstalledSentence(
        sentenceId: s['sentence_id']! as String,
        blockId: json['block_id']! as String,
        order: s['order']! as int,
        text: s['text']! as String,
        runs: [for (final r in s['runs']! as List) _run(r! as Map<String, Object?>)],
      );
    }(),
];

InstalledTableCell _cell(Map<String, Object?> json) => InstalledTableCell(
  cellId: json['cell_id']! as String,
  text: json['text']! as String,
  runs: [
    for (final r in json['runs']! as List)
      _run(r! as Map<String, Object?>),
  ],
);

ArticleRun _run(Map<String, Object?> json) => ArticleRun(
  kind: ArticleRunKind.fromWire(json['kind']! as String)!,
  text: json['text']! as String,
  href: json['href'] as String?,
);
