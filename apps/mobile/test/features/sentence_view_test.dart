import 'package:engirdle_mobile/app/theme.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/reader/presentation/sentence_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const plainRun = [ArticleRun(kind: ArticleRunKind.plain, text: 'Take off now.')];

  testWidgets('selected text actions are dictionary, copy, then local translation', (
    tester,
  ) async {
    await tester.pumpWidget(
      PaletteScope(
        palette: AppPalette.paperPreset,
        child: MaterialApp(
          theme: buildTheme(AppPalette.paperPreset),
          home: Scaffold(
            body: SentenceView(
              sentence: const InstalledSentence(
                sentenceId: 's1',
                blockId: 'b1',
                order: 0,
                text: 'Take off now.',
                runs: plainRun,
              ),
              text: 'Take off now.',
              style: const TextStyle(fontSize: 18),
              playing: false,
              selectable: true,
              onTap: () {},
              onLookup: (_) {},
              onTranslate: (_) {},
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('Take off now.'));
    await tester.pumpAndSettle();

    final toolbar = find.byType(AdaptiveTextSelectionToolbar);
    expect(toolbar, findsOneWidget);
    final labels = tester
        .widgetList<Text>(find.descendant(of: toolbar, matching: find.byType(Text)))
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    expect(labels, ['词典', '复制', '本机翻译']);
  });

  testWidgets('v1.1 runs render as one rich selectable text', (tester) async {
    const runs = [
      ArticleRun(kind: ArticleRunKind.plain, text: 'A '),
      ArticleRun(kind: ArticleRunKind.strong, text: 'bold'),
      ArticleRun(kind: ArticleRunKind.plain, text: ' and an '),
      ArticleRun(kind: ArticleRunKind.link, text: 'link', href: 'https://e.x/y'),
      ArticleRun(kind: ArticleRunKind.hardBreak, text: ''),
      ArticleRun(kind: ArticleRunKind.plain, text: 'tail'),
    ];
    await tester.pumpWidget(
      PaletteScope(
        palette: AppPalette.paperPreset,
        child: MaterialApp(
          theme: buildTheme(AppPalette.paperPreset),
          home: Scaffold(
            body: SentenceView(
              sentence: const InstalledSentence(
                sentenceId: 's1',
                blockId: 'b1',
                order: 0,
                text: 'A bold and an link\ntail',
                runs: runs,
              ),
              text: 'A bold and an link\ntail',
              runs: runs,
              style: const TextStyle(fontSize: 18),
              playing: false,
              selectable: true,
              onTap: () {},
              onLookup: (_) {},
              onTranslate: (_) {},
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    // One selectable unit: the run spans concatenate to the sentence text.
    final span = selectable.textSpan as TextSpan;
    expect(
      span.children!.map((s) => (s as TextSpan).text).join(),
      'A bold and an link\ntail',
    );
    // Link styling: colored + underlined, target http(s) only.
    final linkSpan =
        span.children!.whereType<TextSpan>().firstWhere((s) => s.recognizer != null);
    expect(linkSpan.style!.color, AppPalette.primary);
    expect(linkSpan.style!.decoration, TextDecoration.underline);
  });

  testWidgets('image alt runs keep selection offsets sentence-local', (
    tester,
  ) async {
    // An IMAGE run stands in for the picture with its alt text. The rendered
    // selectable text must equal the sentence text EXACTLY: any prefix glyph
    // would shift selection offsets used for dictionary lookup and local
    // translation (regression for the former '🖼 ' prefix).
    const text = 'See the diagram now.';
    const runs = [
      ArticleRun(kind: ArticleRunKind.plain, text: 'See the '),
      ArticleRun(kind: ArticleRunKind.image, text: 'diagram', href: 'https://e.x/d.png'),
      ArticleRun(kind: ArticleRunKind.plain, text: ' now.'),
    ];
    await tester.pumpWidget(
      PaletteScope(
        palette: AppPalette.paperPreset,
        child: MaterialApp(
          theme: buildTheme(AppPalette.paperPreset),
          home: Scaffold(
            body: SentenceView(
              sentence: const InstalledSentence(
                sentenceId: 's1',
                blockId: 'b1',
                order: 0,
                text: text,
                runs: runs,
              ),
              text: text,
              runs: runs,
              style: const TextStyle(fontSize: 18),
              playing: false,
              selectable: true,
              onTap: () {},
              onLookup: (_) {},
              onTranslate: (_) {},
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    final selectable = tester.widget<SelectableText>(find.byType(SelectableText));
    final span = selectable.textSpan as TextSpan;
    final rendered = span.children!.whereType<TextSpan>().map((s) => s.text);
    expect(rendered.join(), text);
    // No span may inject a glyph prefix that would shift text offsets.
    expect(rendered.any((t) => t != null && t.contains('🖼')), isFalse);
  });
}
