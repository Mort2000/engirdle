import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../contracts/readpack_v1/article.dart';
import '../../library/domain/installed_article.dart';
import 'run_spans.dart';
import 'sentence_view.dart';

/// One installed block in the reader body, dispatched by type (readpack
/// v1.1): text blocks keep the per-sentence interaction model, while table,
/// code and divider blocks are static, non-narratable presentations with no
/// sentence menus and no playback entry points.
class ContentBlockView extends StatelessWidget {
  const ContentBlockView({
    required this.block,
    required this.mode,
    required this.textStyle,
    required this.zhStyle,
    required this.currentSentenceId,
    required this.viewKeys,
    required this.onSentenceTap,
    required this.onLookup,
    required this.onTranslate,
    required this.onSelectionChanged,
    required this.onZhLongPress,
    super.key,
  });

  final InstalledBlock block;
  final ReadingMode mode;
  final TextStyle textStyle;
  final TextStyle zhStyle;
  final String? currentSentenceId;
  final Map<String, GlobalKey<SentenceViewState>> viewKeys;
  final void Function(InstalledSentence) onSentenceTap;
  final void Function(InstalledSentence, String) onLookup;
  final void Function(InstalledSentence, String) onTranslate;
  final void Function(InstalledSentence, bool) onSelectionChanged;
  final VoidCallback onZhLongPress;

  @override
  Widget build(BuildContext context) {
    return switch (block) {
      final InstalledTextBlock text => TextBlockView(
          block: text,
          mode: mode,
          textStyle: textStyle,
          zhStyle: zhStyle,
          currentSentenceId: currentSentenceId,
          viewKeys: viewKeys,
          onSentenceTap: onSentenceTap,
          onLookup: onLookup,
          onTranslate: onTranslate,
          onSelectionChanged: onSelectionChanged,
          onZhLongPress: onZhLongPress,
        ),
      final InstalledTableBlock table => TableBlockView(
          block: table,
          mode: mode,
          textStyle: textStyle,
          zhStyle: zhStyle,
        ),
      final InstalledCodeBlock code =>
        CodeBlockView(block: code, textStyle: textStyle),
      final InstalledDividerBlock _ => const DividerBlockView(),
    };
  }
}

/// paragraph / heading / list_item / quote: the per-sentence reading modes
/// (MOB-READ-002) with block-level typography.
class TextBlockView extends StatelessWidget {
  const TextBlockView({
    required this.block,
    required this.mode,
    required this.textStyle,
    required this.zhStyle,
    required this.currentSentenceId,
    required this.viewKeys,
    required this.onSentenceTap,
    required this.onLookup,
    required this.onTranslate,
    required this.onSelectionChanged,
    required this.onZhLongPress,
    super.key,
  });

  final InstalledTextBlock block;
  final ReadingMode mode;
  final TextStyle textStyle;
  final TextStyle zhStyle;
  final String? currentSentenceId;
  final Map<String, GlobalKey<SentenceViewState>> viewKeys;
  final void Function(InstalledSentence) onSentenceTap;
  final void Function(InstalledSentence, String) onLookup;
  final void Function(InstalledSentence, String) onTranslate;
  final void Function(InstalledSentence, bool) onSelectionChanged;
  final VoidCallback onZhLongPress;

  /// Heading sizing ladder relative to the user's base font size.
  static const _headingScale = [1.55, 1.4, 1.25, 1.12, 1.0, 0.95];

  @override
  Widget build(BuildContext context) {
    final palette = PaletteScope.of(context);
    final style = switch (block.kind) {
      ArticleTextKind.heading => textStyle.copyWith(
          fontSize:
              (textStyle.fontSize ?? 16) * _headingScale[(block.level ?? 1) - 1],
          fontWeight: FontWeight.w700,
          height: 1.35,
        ),
      _ => textStyle,
    };

    final children = <Widget>[];
    for (final sentence in block.sentences) {
      final playing = sentence.sentenceId == currentSentenceId;
      switch (mode) {
        case ReadingMode.enOnly:
          children.add(_sentence(sentence, playing, style, selectable: true));
        case ReadingMode.bilingual:
          children
            ..add(_sentence(sentence, playing, style, selectable: true))
            ..add(
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4, bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: palette.paper2,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(sentence.translationZh ?? '', style: zhStyle),
              ),
            );
        case ReadingMode.zhOnly:
          children.add(
            SentenceView(
              key: viewKeys[sentence.sentenceId],
              sentence: sentence,
              text: sentence.translationZh ?? '',
              // Serif stays in zh-only too (design reader typography): the
              // base textStyle already carries the user's font preference.
              style: style,
              playing: playing,
              selectable: false,
              onTap: () => onSentenceTap(sentence),
              onLookup: (_) {},
              onTranslate: (_) {},
              onSelectionChanged: (_) {},
              onLongPressHint: onZhLongPress,
            ),
          );
      }
    }
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
    return switch (block.kind) {
      ArticleTextKind.heading => Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 11),
          child: body,
        ),
      ArticleTextKind.listItem => Padding(
          padding: EdgeInsets.only(
            left: 16.0 * block.listDepth,
            bottom: 11,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 7),
                child: Text(
                  _listMarker(),
                  style: style.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ArticleTextKind.quote => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 11),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: palette.playHighlightBorder,
                width: (2 + block.quoteDepth).toDouble(),
              ),
            ),
          ),
          padding:
              EdgeInsets.only(left: 8.0 + 3.0 * block.quoteDepth, top: 1),
          child: body,
        ),
      ArticleTextKind.paragraph => Padding(
          padding: const EdgeInsets.only(bottom: 11),
          child: body,
        ),
    };
  }

  Widget _sentence(
    InstalledSentence sentence,
    bool playing,
    TextStyle style, {
    required bool selectable,
  }) {
    return SentenceView(
      key: viewKeys[sentence.sentenceId],
      sentence: sentence,
      text: sentence.text,
      runs: sentence.runs,
      style: style,
      playing: playing,
      selectable: selectable,
      onTap: () => onSentenceTap(sentence),
      onLookup: (selection) => onLookup(sentence, selection),
      onTranslate: (selection) => onTranslate(sentence, selection),
      onSelectionChanged: (hasSelection) =>
          onSelectionChanged(sentence, hasSelection),
    );
  }

  String _listMarker() => switch (block.listKind) {
        ArticleListKind.ordered =>
          block.listOrdinal == null ? '1.' : '${block.listOrdinal}.',
        ArticleListKind.bullet => '•',
        null => '•',
      };
}

/// Static table presentation: horizontal scroll, fixed wrapping columns,
/// alignment honored, selectable cells — and no sentence menu, no playback.
/// Bilingual stacks original + translation in the same grid cell; zh-only
/// shows the translated table.
class TableBlockView extends StatelessWidget {
  const TableBlockView({
    required this.block,
    required this.mode,
    required this.textStyle,
    required this.zhStyle,
    super.key,
  });

  final InstalledTableBlock block;
  final ReadingMode mode;
  final TextStyle textStyle;
  final TextStyle zhStyle;

  static const _columnWidth = 160.0;

  @override
  Widget build(BuildContext context) {
    final palette = PaletteScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          columnWidths: {
            for (var i = 0; i < block.header.length; i++)
              i: const FixedColumnWidth(_columnWidth),
          },
          border: TableBorder.all(color: palette.outline, width: 0.7),
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          children: [
            TableRow(
              decoration: BoxDecoration(color: palette.paper2),
              children: [
                for (var i = 0; i < block.header.length; i++)
                  _TableCellView(
                    cell: block.header[i],
                    translation:
                        block.translationById[block.header[i].cellId] ?? '',
                    alignment: block.alignments[i],
                    isHeader: true,
                    mode: mode,
                    textStyle: textStyle,
                    zhStyle: zhStyle,
                  ),
              ],
            ),
            for (final row in block.rows)
              TableRow(
                children: [
                  for (var i = 0; i < row.length; i++)
                    _TableCellView(
                      cell: row[i],
                      translation: block.translationById[row[i].cellId] ?? '',
                      alignment: i < block.alignments.length
                          ? block.alignments[i]
                          : TableAlignment.inherit,
                      isHeader: false,
                      mode: mode,
                      textStyle: textStyle,
                      zhStyle: zhStyle,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _TableCellView extends StatelessWidget {
  const _TableCellView({
    required this.cell,
    required this.translation,
    required this.alignment,
    required this.isHeader,
    required this.mode,
    required this.textStyle,
    required this.zhStyle,
  });

  final InstalledTableCell cell;

  /// The cell's translated text (empty when unknown).
  final String translation;

  final TableAlignment alignment;
  final bool isHeader;
  final ReadingMode mode;
  final TextStyle textStyle;
  final TextStyle zhStyle;

  TextAlign get _textAlign => switch (alignment) {
        TableAlignment.left => TextAlign.left,
        TableAlignment.center => TextAlign.center,
        TableAlignment.right => TextAlign.right,
        TableAlignment.inherit => TextAlign.start,
      };

  @override
  Widget build(BuildContext context) {
    final palette = PaletteScope.of(context);
    final style = textStyle.copyWith(
      fontSize: (textStyle.fontSize ?? 16) * 0.92,
      fontWeight: isHeader ? FontWeight.w700 : null,
    );
    final Widget content = switch (mode) {
      ReadingMode.enOnly => _original(style, palette),
      ReadingMode.bilingual => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _original(style, palette),
            const SizedBox(height: 4),
            Text(
              translation,
              style: zhStyle,
              textAlign: _textAlign,
            ),
          ],
        ),
      ReadingMode.zhOnly => Text(
          translation,
          style: zhStyle,
          textAlign: _textAlign,
        ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
      child: content,
    );
  }

  Widget _original(TextStyle style, AppPalette palette) {
    if (cell.runs.isEmpty) {
      return SelectableText(
        cell.text,
        style: style,
        textAlign: _textAlign,
      );
    }
    return SelectableText.rich(
      TextSpan(
        style: style,
        children: buildRunSpans(runs: cell.runs, palette: palette),
      ),
      textAlign: _textAlign,
    );
  }
}

/// Static code presentation: monospace, horizontal scroll, whole-block copy
/// via the selection area. Code is never interpreted, never translated and
/// never narrated (COMPATIBILITY.md).
class CodeBlockView extends StatelessWidget {
  const CodeBlockView({required this.block, required this.textStyle, super.key});

  final InstalledCodeBlock block;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final palette = PaletteScope.of(context);
    final codeStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: (textStyle.fontSize ?? 16) * 0.85,
      height: 1.5,
      color: palette.ink,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: palette.paper2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.outline, width: 0.7),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (block.language case final language?)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  language,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: palette.inkVariant,
                  ),
                ),
              ),
            SelectionArea(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  block.code,
                  style: codeStyle,
                  softWrap: false,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain themed rule; identical in every reading mode.
class DividerBlockView extends StatelessWidget {
  const DividerBlockView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Divider(thickness: 1, height: 1),
    );
  }
}
