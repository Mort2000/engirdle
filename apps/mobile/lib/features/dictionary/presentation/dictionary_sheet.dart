import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../shared_kernel/content_identity.dart';
import '../../library/domain/installed_article.dart';
import '../../vocabulary/application/vocabulary_service.dart';
import '../../vocabulary/domain/vocabulary_entry.dart';
import '../domain/dictionary_models.dart';

class DictionarySheet extends StatefulWidget {
  const DictionarySheet({
    required this.selection,
    required this.result,
    required this.resource,
    required this.article,
    required this.ref,
    required this.sentenceText,
    this.sentenceTranslationZh,
    required this.vocabulary,
    required this.onTranslateLocally,
    super.key,
  });

  final String selection;
  final DictionaryResult result;
  final DictionaryResource resource;
  final InstalledArticle article;
  final SentenceRef ref;
  final String sentenceText;
  final String? sentenceTranslationZh;
  final VocabularyService vocabulary;
  final VoidCallback onTranslateLocally;

  @override
  State<DictionarySheet> createState() => _DictionarySheetState();
}

class _DictionarySheetState extends State<DictionarySheet> {
  final _savedSenseIds = <String>{};

  @override
  void initState() {
    super.initState();
    _savedSenseIds.addAll(
      widget.vocabulary.savedSenseIds(
        resource: widget.resource,
        ref: widget.ref,
      ),
    );
  }

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
    if (mounted) setState(() => _savedSenseIds.remove(entry.senseId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = PaletteScope.of(context);
    final result = widget.result;
    final parts = <String>[];
    for (final sense in result.senses) {
      if (!parts.contains(sense.partOfSpeech)) parts.add(sense.partOfSpeech);
    }
    final needsTranslationFallback =
        !result.found ||
        result.senses.any((sense) => sense.translations.isEmpty);
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Scaffold(
        backgroundColor: palette.surface,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SheetHandle(),
                Text(
                  result.surface,
                  style: const TextStyle(
                    fontFamily: 'serif',
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (parts.isNotEmpty) parts.join(' / '),
                    if (result.lemma != null) '原形 ${result.lemma}',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
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
                                  '可尝试选择更短的词或单个单词。词典不会根据上下文编造词义。',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
                if (needsTranslationFallback)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: widget.onTranslateLocally,
                      icon: const Icon(Icons.translate, size: 16),
                      label: const Text('本机翻译'),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  '来源：${widget.resource.sources.map((source) => source.displayName).join(' · ')}',
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
    required this.saved,
    required this.onSave,
  });

  final int index;
  final DictionarySense sense;
  final bool saved;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = PaletteScope.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Row(
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
                  Text(sense.partOfSpeech, style: theme.textTheme.bodySmall),
                  if (sense.glossEn case final gloss?)
                    Text(
                      gloss,
                      style: const TextStyle(fontSize: 13, fontFamily: 'serif'),
                    ),
                  if (sense.translations.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        sense.translations
                            .map((translation) => translation.displayLemma)
                            .join('；'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.inkVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Semantics(
              label: saved ? '已保存' : '保存该义项',
              button: true,
              child: IconButton(
                tooltip: saved ? '已保存' : '保存该义项',
                visualDensity: VisualDensity.compact,
                onPressed: saved ? null : onSave,
                icon: Icon(
                  saved ? Icons.bookmark : Icons.bookmark_add_outlined,
                  size: 20,
                  color: saved ? theme.colorScheme.primary : null,
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
