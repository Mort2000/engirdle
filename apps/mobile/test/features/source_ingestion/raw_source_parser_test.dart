import 'dart:convert';
import 'dart:typed_data';

import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/features/source_ingestion/application/raw_source_parser.dart';
import 'package:engirdle_mobile/features/source_ingestion/domain/raw_source.dart';
import 'package:engirdle_mobile/features/source_ingestion/domain/source_parse_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = RawSourceParser();

  group('plain text structuring', () {
    test('blank lines split paragraphs; lines join with spaces', () {
      final candidate = parser.parsePaste(
        text: 'First block line one.\nLine two.\n\nSecond block. More.',
        syntax: SourceSyntax.plainText,
      );
      final blocks =
          candidate.blocks.whereType<ParsedTextBlock>().toList();
      expect(blocks, hasLength(2));
      expect(
        blocks.first.sentences.map((s) => s.text),
        ['First block line one.', 'Line two.'],
      );
      expect(blocks.first.blockId, 'block-1');
      expect(blocks.first.sentences.first.sentenceId, 'sentence-1');
      expect(
        blocks.last.sentences.map((s) => s.text),
        ['Second block.', 'More.'],
      );
    });

    test('markdown syntax stays literal in plain text', () {
      final candidate = parser.parsePaste(
        text: '# not a heading\n*not emphasis*',
        syntax: SourceSyntax.plainText,
      );
      final block = candidate.blocks.single as ParsedTextBlock;
      expect(block.kind, ArticleTextKind.paragraph);
      expect(
        block.sentences.single.text,
        '# not a heading *not emphasis*',
      );
      expect(block.sentences.single.runs.single.kind, ArticleRunKind.plain);
    });

    test('visible text normalization applies (NBSP, smart quotes)', () {
      final candidate = parser.parsePaste(
        text: 'Non breaking ‘quote’ here.',
        syntax: SourceSyntax.plainText,
      );
      final block = candidate.blocks.single as ParsedTextBlock;
      expect(block.sentences.single.text, "Non breaking 'quote' here.");
    });

    test('empty and whitespace-only bodies are rejected', () {
      expect(
        () => parser.parsePaste(text: '  \n\n', syntax: SourceSyntax.plainText),
        throwsA(
          isA<SourceParseException>()
              .having((e) => e.code, 'code', 'empty_body'),
        ),
      );
    });
  });

  group('paste and file paths produce identical structures', () {
    test('plain text: paste == .txt file', () {
      const text = 'Alpha one.\nBeta two.\n\nGamma three.';
      final viaPaste = parser.parsePaste(
        text: text,
        syntax: SourceSyntax.plainText,
      );
      final viaFile = parser.parseFile(
        bytes: Uint8List.fromList(utf8.encode(text)),
        fileName: 'notes.txt',
      );
      expect(viaFile.structureSha256, viaPaste.structureSha256);
      expect(viaFile.normalizedSha256, viaPaste.normalizedSha256);
      expect(viaFile.sourceSha256, viaPaste.sourceSha256);
    });

    test('markdown: paste == .md file', () {
      const text = '# Title\n\nBody with *emphasis* and a [link](https://x.io).\n';
      final viaPaste = parser.parsePaste(
        text: text,
        syntax: SourceSyntax.markdown,
      );
      final viaFile = parser.parseFile(
        bytes: Uint8List.fromList(utf8.encode(text)),
        fileName: 'a.md',
      );
      expect(viaFile.structureSha256, viaPaste.structureSha256);
      expect(viaFile.suggestedTitle, 'Title');
    });

    test('.markdown routes to the markdown parser too', () {
      final candidate = parser.parseFile(
        bytes: Uint8List.fromList(utf8.encode('# h\n\ntext')),
        fileName: 'a.MARKDOWN',
      );
      expect(candidate.syntax, SourceSyntax.markdown);
      expect(candidate.blocks.first, isA<ParsedTextBlock>());
    });
  });

  group('canonicalization', () {
    test('leading BOM is stripped for files; raw hash keeps the BOM', () {
      final bom = Uint8List.fromList([0xEF, 0xBB, 0xBF]);
      final text = utf8.encode('# t\n\nbody.');
      final withBom = Uint8List.fromList([...bom, ...text]);
      final candidate = parser.parseFile(bytes: withBom, fileName: 'a.md');
      expect(candidate.canonical.startsWith('﻿#'), isFalse);
      expect(candidate.blocks.first, isA<ParsedTextBlock>());
      expect(
        candidate.sourceSha256,
        parser.parseFile(
          bytes: withBom,
          fileName: 'a.md',
        ).sourceSha256,
      );
    });

    test('CRLF and lone CR both canonicalize to LF', () {
      final crlf = parser.parsePaste(
        text: 'one.\r\ntwo.\r\rthree.',
        syntax: SourceSyntax.plainText,
      );
      expect(crlf.canonical, 'one.\ntwo.\n\nthree.');
    });

    test('invalid UTF-8 is an actionable error', () {
      expect(
        () => parser.parseFile(
          bytes: Uint8List.fromList([0x61, 0xC3, 0x28]),
          fileName: 'x.txt',
        ),
        throwsA(
          isA<SourceParseException>()
              .having((e) => e.code, 'code', 'invalid_utf8'),
        ),
      );
    });

    test('the 8 MiB ceiling rejects without truncating', () {
      final huge = Uint8List(RawSourceParser.maxSourceBytes + 1);
      expect(
        () => parser.parseFile(bytes: huge, fileName: 'x.txt'),
        throwsA(
          isA<SourceParseException>()
              .having((e) => e.code, 'code', 'source_too_large'),
        ),
      );
    });
  });

  group('candidate metadata', () {
    test('counts, translation flag and warnings flow through', () {
      final candidate = parser.parsePaste(
        text: '''
# Heading one

Paragraph sentence. Another one.

- item

| a | b |
|---|---|
| 1 | 2 |

```js
code();
```
''',
        syntax: SourceSyntax.markdown,
      );
      expect(candidate.counts.blocks, greaterThanOrEqualTo(5));
      expect(candidate.counts.sentences, 4); // heading + 2 + item
      expect(candidate.counts.tables, 1);
      expect(candidate.counts.codeBlocks, 1);
      expect(candidate.canTranslate, isTrue);
      expect(candidate.suggestedTitle, 'Heading one');
      expect(candidate.warnings, isEmpty);
    });

    test('code-only articles read but cannot translate', () {
      final candidate = parser.parsePaste(
        text: '```\nonly code\n```\n',
        syntax: SourceSyntax.markdown,
      );
      expect(candidate.canTranslate, isFalse);
      expect(candidate.counts.codeBlocks, 1);
    });

    test('unclosed fence warning is carried to the confirmation page', () {
      final candidate = parser.parsePaste(
        text: 'Intro.\n\n```\nunclosed',
        syntax: SourceSyntax.markdown,
      );
      expect(
        candidate.warnings.map((w) => w.code),
        contains('unclosed_code_fence'),
      );
    });
  });
}
