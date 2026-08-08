import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/scope.dart';
import '../../../app/theme.dart';
import '../domain/vocabulary_entry.dart';

/// Screen 12B — vocabulary detail with the full frozen snapshot.
class VocabDetailPage extends StatelessWidget {
  const VocabDetailPage({required this.vocabularyId, super.key});

  final String vocabularyId;

  @override
  Widget build(BuildContext context) {
    final deps = AppScope.of(context);
    final entry = deps.vocabulary.byId(vocabularyId);
    final theme = Theme.of(context);
    if (entry == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('生词详情')),
        body: const Center(child: Text('该生词已删除')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('生词详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, entry),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Text(
            entry.surface,
            style: const TextStyle(
                fontFamily: 'serif',
                fontSize: 21,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (entry.lemma != null) '原形 ${entry.lemma}',
              if (entry.partOfSpeech != null) entry.partOfSpeech!,
              '保存于 ${formatDate(entry.createdAt)}',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('选定义项 · 来自 ${entry.sourceName}',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(height: 3),
                  Text(
                    '${entry.partOfSpeech ?? ''} ${entry.senseEn}'.trim(),
                    style:
                        const TextStyle(fontFamily: 'serif', fontSize: 13),
                  ),
                  if (entry.senseZh != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text('英中：${entry.senseZh}',
                          style: theme.textTheme.bodySmall),
                    ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('上下文（保存时冻结）', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 3),
                  Text(
                    '“${entry.sentenceText}”',
                    style:
                        const TextStyle(fontFamily: 'serif', fontSize: 13),
                  ),
                  if (entry.sentenceTranslationZh != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(entry.sentenceTranslationZh!,
                          style: theme.textTheme.bodySmall),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      '出处：《${entry.articleTitle}》第 ${entry.ref.revision} 版',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppPalette.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(12),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 17, color: Color(0xFF234534)),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '本机文章升级或被删除后，此处仍按保存时的原句与译文完整显示，不受文章变化影响。',
                    style: TextStyle(fontSize: 12, color: Color(0xFF234534)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  foregroundColor: AppPalette.error),
              onPressed: () => _confirmDelete(context, entry),
              icon: const Icon(Icons.delete_outline, size: 15),
              label: const Text('删除该生词'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, VocabularyEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条生词？'),
        content: Text('将从生词本中删除「${entry.surface}」。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppPalette.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      AppScope.of(context).vocabulary.delete(entry.vocabularyId);
      Navigator.of(context).pop();
    }
  }
}
