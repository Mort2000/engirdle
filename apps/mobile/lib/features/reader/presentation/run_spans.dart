import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../contracts/readpack_v1/article.dart';

/// Maps contract inline runs to styled [TextSpan]s. Shared by the sentence
/// view, table cells and anywhere v1.1 runs render, so emphasis/strong/
/// strikethrough/code/link/image/hard_break look identical everywhere.
///
/// Spans carry only style *deltas*: the caller sets the base style on the
/// root span (or the SelectableText), and these deltas merge on top.
List<InlineSpan> buildRunSpans({
  required List<ArticleRun> runs,
  required AppPalette palette,
  GestureRecognizer? Function(ArticleRun run)? recognizerFor,
}) {
  return [
    for (final run in runs) _spanFor(run, palette, recognizerFor),
  ];
}

InlineSpan _spanFor(
  ArticleRun run,
  AppPalette palette,
  GestureRecognizer? Function(ArticleRun run)? recognizerFor,
) {
  switch (run.kind) {
    case ArticleRunKind.plain:
      return TextSpan(text: run.text);
    case ArticleRunKind.emphasis:
      return TextSpan(
        text: run.text,
        style: const TextStyle(fontStyle: FontStyle.italic),
      );
    case ArticleRunKind.strong:
      return TextSpan(
        text: run.text,
        style: const TextStyle(fontWeight: FontWeight.w700),
      );
    case ArticleRunKind.strikethrough:
      return TextSpan(
        text: run.text,
        style: TextStyle(
          decoration: TextDecoration.lineThrough,
          decorationColor: palette.inkVariant,
        ),
      );
    case ArticleRunKind.code:
      return TextSpan(
        text: run.text,
        style: TextStyle(
          fontFamily: 'monospace',
          background: Paint()..color = palette.paper2,
        ),
      );
    case ArticleRunKind.link:
      return TextSpan(
        text: run.text,
        style: TextStyle(
          color: AppPalette.primary,
          decoration: TextDecoration.underline,
          decorationColor: AppPalette.primary,
        ),
        recognizer: recognizerFor?.call(run),
      );
    case ArticleRunKind.image:
      // The alt text stands in for the image (the readpack layout carries no
      // image assets). It must render EXACTLY run.text with no glyph prefix:
      // selection offsets index Sentence.text, so any extra characters would
      // shift dictionary lookups and local translation spans.
      return TextSpan(
        text: run.text,
        style: TextStyle(
          color: palette.inkVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    case ArticleRunKind.hardBreak:
      return const TextSpan(text: '\n');
  }
}
