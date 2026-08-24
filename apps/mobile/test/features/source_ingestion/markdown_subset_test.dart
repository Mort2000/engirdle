import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/features/source_ingestion/domain/source_parse_error.dart';
import 'package:engirdle_mobile/features/source_ingestion/infrastructure/markdown_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mobile-subset boundaries beyond the shared corpus (contracts/source/v1
/// README): these inputs are accepted by PC but rejected here, plus the
/// scheme-rejected link rendering both sides share.
void main() {
  test('link reference definitions are rejected', () {
    expect(
      () => parseMarkdownSource('[label]: https://example.com/ "t"\n\nText.'),
      throwsA(
        isA<SourceParseException>().having(
          (e) => e.code,
          'code',
          'link_reference_definition',
        ),
      ),
    );
  });

  test('reference-style brackets stay literal when no definition exists', () {
    final parsed = parseMarkdownSource('See [foo][1] and [bar] now.');
    expect(parsed.blocks.single, isNotNull);
  });

  test('uri and email autolinks are rejected', () {
    expect(
      () => parseMarkdownSource('See <https://example.com/a> now.'),
      throwsA(
        isA<SourceParseException>().having((e) => e.code, 'code', 'autolink'),
      ),
    );
    expect(
      () => parseMarkdownSource('Mail <a.b@example.com> now.'),
      throwsA(
        isA<SourceParseException>().having((e) => e.code, 'code', 'autolink'),
      ),
    );
  });

  test('angle literals without tag/autolink shape stay literal', () {
    final parsed = parseMarkdownSource('a < b and c > d are fine.');
    expect(parsed.blocks.single, isNotNull);
  });

  test('html entities are rejected; bare ampersand stays literal', () {
    expect(
      () => parseMarkdownSource('Tom &amp; Jerry'),
      throwsA(
        isA<SourceParseException>().having(
          (e) => e.code,
          'code',
          'html_entity',
        ),
      ),
    );
    // Without a semicolon (or with a following space) the entity never
    // forms: literal text on both platforms. Well-formed but unknown names
    // like &notanentity; are rejected by the mobile subset — deliberately
    // narrower than PC, which renders them literally (contracts/source/v1).
    final parsed = parseMarkdownSource('Tom &amp Jerry and & bleep are fine.');
    final block = parsed.blocks.single as ParsedTextBlock;
    expect(block.sentences.single.text, 'Tom &amp Jerry and & bleep are fine.');
  });

  test('scheme-rejected links stay literal (validateLink parity)', () {
    final parsed = parseMarkdownSource(
      'Click [here](javascript:alert(1)) now.',
    );
    final block = parsed.blocks.single as ParsedTextBlock;
    expect(block.sentences.single.runs.single.kind, ArticleRunKind.plain);
    expect(
      block.sentences.single.text,
      'Click [here](javascript:alert(1)) now.',
    );
  });

  test('nesting beyond four levels is rejected', () {
    expect(
      () => parseMarkdownSource('> > > > > too deep quote\n\ntext'),
      throwsA(
        isA<SourceParseException>().having(
          (e) => e.code,
          'code',
          'nesting_depth',
        ),
      ),
    );
  });

  test('deep list nesting beyond four is rejected', () {
    final deep = [
      for (var i = 1; i <= 5; i++) '${'  ' * (i - 1)}- level $i',
    ].join('\n');
    expect(
      () => parseMarkdownSource(deep),
      throwsA(
        isA<SourceParseException>().having(
          (e) => e.code,
          'code',
          'nesting_depth',
        ),
      ),
    );
  });

  test('empty body is rejected', () {
    expect(
      () => parseMarkdownSource('   \n\n  '),
      throwsA(
        isA<SourceParseException>().having((e) => e.code, 'code', 'empty_body'),
      ),
    );
  });
}
