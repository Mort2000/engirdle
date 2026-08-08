import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../shared_kernel/content_identity.dart';
import '../../library/domain/installed_article.dart';
import '../../vocabulary/application/vocabulary_service.dart';
import '../../vocabulary/domain/vocabulary_entry.dart';
import '../application/dictionary_service.dart';
import '../domain/dictionary_models.dart';

/// Screen 10A — the offline dictionary result drawer.
///
/// - default gloss language follows the menu entry (英英翻译 / 英中翻译);
/// - 英英 is the primary order and default; the segmented control switches
///   the whole drawer (design 假设⑩, MOB-DIC-003);
/// -「保存该义项」saves in one step (UX-A1, MOB-VOC-001) with undo via
///   snackbar; the sheet stays open for further lookups.
class DictionarySheet extends StatefulWidget {
  const DictionarySheet({
    required this.selection,
    required this.preferChinese,
    required this.result,
    required this.resource,
    required this.article,
    required this.ref,
    required this.sentenceText,
    this.sentenceTranslationZh,
    required this.dictionary,
    required this.vocabulary,
    super.key,
  });

  final String selection;
  final bool preferChinese;
  final DictionaryResult result;
  final DictionaryResource resource;
  final InstalledArticle article;
  final SentenceRef ref;
  final String sentenceText;
  final String? sentenceTranslationZh;
  final DictionaryService dictionary;
  final VocabularyService vocabulary;

  @override
  State<DictionarySheet> createState() => _DictionarySheetState();
}

class _DictionarySheetState extends State<DictionarySheet> {
  late bool _showChinese = widget.preferChinese;
  final _savedSenseIds = <String>{};

  void _save(DictionarySense sense) {
    final entry = widget.vocabulary.saveSense(
      surface: widget.result.surface,
      normalized: widget.result.normalized,
      sense: sense,
      lemma: widget.result.lemma,
      resource: widget.resource,
      ref: widget.ref,
      sentenceText: widget.sentenceText,
      sentenceTranslationZh: widget.sentenceTranslationZh,
      article: widget.article,
    );
    setState(() => _savedSenseIds.add(sense.senseId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF234534),
        content: Text('已保存 ${widget.result.surface} 到生词本'),
        action: SnackBarAction(label: '撤销', onPressed: () => _undo(entry)),
      ),
    );
  }

  void _undo(VocabularyEntry entry) {
    widget.vocabulary.undoSave(entry.vocabularyId);
    if (mounted) {
      setState(() => _savedSenseIds.remove(entry.senseId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = PaletteScope.of(context);
    final result = widget.result;
    // Part-of-speech summary for the header (s10): deduped, in lookup order.
    final parts = <String>[];
    for (final sense in result.senses) {
      if (!parts.contains(sense.partOfSpeech)) parts.add(sense.partOfSpeech);
    }
    final posSummary = parts.join(' / ');
    return ClipRRect(
      // The Scaffold below paints an opaque background; clip it to the
      // drawer's rounded top (bottomSheetTheme radius 20) so the corners
      // keep their current look.
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Scaffold(
        // UX-A1: the sheet needs its own Scaffold so the save/undo snackbar
        // is presented inside the drawer. ScaffoldMessenger presents on
        // every registered root Scaffold; without this one the snackbar only
        // lived on the reader page's Scaffold, hidden and unreachable behind
        // the modal scrim while the sheet is open.
        backgroundColor: palette.surface,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SheetHandle(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        result.surface,
                        style: const TextStyle(
                          fontFamily: 'serif',
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('英英')),
                        ButtonSegment(value: true, label: Text('英中')),
                      ],
                      selected: {_showChinese},
                      onSelectionChanged: (selection) =>
                          setState(() => _showChinese = selection.first),
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (posSummary.isNotEmpty) posSummary,
                    if (result.lemma != null) '原形 ${result.lemma}',
                    '释义语言随菜单选择默认（本次：${widget.preferChinese ? '英中' : '英英'}），可随时切换',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
                // s10: when the exact lookup missed and the forms table supplied
                // a lemma, say what the glosses below actually belong to.
                if (result.lemma != null)
                  Text(
                    '已找到 ${result.lemma} 的相关释义',
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                Flexible(
                  child: result.found
                      ? ListView.builder(
                          shrinkWrap: true,
                          itemCount: result.senses.length,
                          itemBuilder: (context, index) => _SenseCard(
                            index: index + 1,
                            sense: result.senses[index],
                            showChinese: _showChinese,
                            saved: _savedSenseIds.contains(
                              result.senses[index].senseId,
                            ),
                            onSave: () => _save(result.senses[index]),
                          ),
                        )
                      : Card(
                          child: Padding(
                            padding: const EdgeInsets.all(13),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '“${result.surface}” 未找到词条',
                                  style: theme.textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '已尝试多种匹配方式均无结果。\n提示：可尝试选择更短的词或单个单词。词典不会根据上下文编造词义。',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 6),
                Text(
                  '英英优先（默认）；从菜单选「英中翻译」进入时默认英中、可切回英英 · 数据源：${widget.resource.displayName}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SenseCard extends StatelessWidget {
  const _SenseCard({
    required this.index,
    required this.sense,
    required this.showChinese,
    required this.saved,
    required this.onSave,
  });

  final int index;
  final DictionarySense sense;
  final bool showChinese;
  final bool saved;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gloss = showChinese
        ? (sense.glossZh ?? sense.glossEn)
        : sense.glossEn;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$index.',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sense.partOfSpeech,
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        gloss,
                        style: TextStyle(
                          fontSize: 13,
                          fontFamily: showChinese ? null : 'serif',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: saved
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppPalette.okContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check, size: 11, color: AppPalette.ok),
                          SizedBox(width: 4),
                          Text(
                            '已保存到生词本',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.ok,
                            ),
                          ),
                        ],
                      ),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: onSave,
                      icon: const Icon(Icons.bookmark_add_outlined, size: 14),
                      label: const Text('保存该义项'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 5,
                        ),
                        textStyle: const TextStyle(fontSize: 11.5),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 6, bottom: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outline,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
