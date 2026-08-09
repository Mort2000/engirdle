import 'package:engirdle_mobile/app/theme.dart';
import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/reader/presentation/sentence_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
