import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/router.dart';
import '../../../app/scope.dart';
import '../../../app/theme.dart';
import '../domain/vocabulary_entry.dart';

/// Screens 12A / 17B — the vocabulary book (view + delete only; no review
/// scheduling, quizzes or proficiency tracking — MVP exclusions).
class VocabBookPage extends StatefulWidget {
  const VocabBookPage({super.key});

  @override
  State<VocabBookPage> createState() => _VocabBookPageState();
}

class _VocabBookPageState extends State<VocabBookPage> {
  List<VocabularyEntry> _entries = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    setState(() => _entries = AppScope.of(context).vocabulary.list());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('生词本'),
            Text(
              '${_entries.length} 条 · 按保存时间排序',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
        children: [
          if (_entries.isEmpty) ...[
            const SizedBox(height: 16),
            CircleAvatar(
              radius: 36,
              backgroundColor: PaletteScope.of(context).paper2,
              child: Icon(
                Icons.bookmark_border,
                size: 32,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Center(child: Text('生词本还是空的', style: theme.textTheme.titleMedium)),
            const SizedBox(height: 4),
            Text(
              '在阅读器内长按单词 → 英英/英中翻译 → 保存义项后，\n生词会出现在这里。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ] else
            for (final entry in _entries)
              _VocabTile(
                entry: entry,
                onTap: () async {
                  await Navigator.of(context).pushNamed(
                    AppRoutes.vocabularyDetail,
                    arguments: entry.vocabularyId,
                  );
                  _reload();
                },
              ),
          const SizedBox(height: 14),
          Card(
            color: PaletteScope.of(context).paper2,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '生词本仅支持查看与删除；MVP 不提供复习计划、测验或熟练度跟踪。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VocabTile extends StatelessWidget {
  const _VocabTile({required this.entry, required this.onTap});

  final VocabularyEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headline = StringBuffer(entry.surface);
    if (entry.lemma != null) headline.write(' · ${entry.lemma}');
    if (entry.partOfSpeech != null) headline.write(' · ${entry.partOfSpeech}');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    headline.toString(),
                    style: const TextStyle(
                      fontFamily: 'serif',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    entry.senseZh ?? entry.senseEn ?? '无可用释义',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '出自《${entry.articleTitle}》第 ${entry.ref.revision} 版 · ${formatRelative(entry.createdAt)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
