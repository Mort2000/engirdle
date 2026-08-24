import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../library/domain/installed_article.dart';

/// Screen 06A — the sentence menu (bottom sheet, uniform shape).
class SentenceMenuSheet extends StatelessWidget {
  const SentenceMenuSheet({
    required this.label,
    required this.translationEnabled,
    required this.playbackEnabled,
    required this.onTranslate,
    required this.onPlaySentence,
    required this.onPlayContinuous,
    super.key,
  });

  final String label;

  /// Disabled in zh-only mode (already reading the translation) or when no
  /// active translation set exists.
  final bool translationEnabled;

  /// Hidden entirely when the article has no narration asset — there is
  /// nothing to play and no fake placeholder audio.
  final bool playbackEnabled;
  final VoidCallback onTranslate;
  final VoidCallback onPlaySentence;
  final VoidCallback onPlayContinuous;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Handle(),
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            child: Text('句子菜单 · $label', style: theme.textTheme.bodySmall),
          ),
          _MenuRow(
            icon: Icons.translate,
            title: '单句翻译',
            subtitle: translationEnabled ? '在抽屉中查看本句中文译文，不改动原文区' : '当前已是译文模式',
            enabled: translationEnabled,
            onTap: onTranslate,
          ),
          if (playbackEnabled) ...[
            _MenuRow(
              icon: Icons.play_arrow,
              title: '单句朗读',
              subtitle: '从本句开始位置播放，句末自动停止',
              onTap: onPlaySentence,
            ),
            _MenuRow(
              icon: Icons.play_arrow,
              title: '从此开始朗读',
              subtitle: '从本句连续播放至文章结尾',
              onTap: onPlayContinuous,
            ),
          ],
        ],
      ),
    );
  }
}

/// Screen 06B — single-sentence translation drawer. The reading area is
/// never modified; translation only appears inside the sheet.
class SentenceTranslationSheet extends StatelessWidget {
  const SentenceTranslationSheet({
    required this.label,
    required this.sentence,
    required this.playbackEnabled,
    required this.onPlaySentence,
    required this.onPlayContinuous,
    super.key,
  });

  final String label;
  final InstalledSentence sentence;

  /// Play buttons render only when the article has a narration asset.
  final bool playbackEnabled;

  final VoidCallback onPlaySentence;
  final VoidCallback onPlayContinuous;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Handle(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '单句翻译 · $label',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            Text(
              '“${sentence.text}”',
              style: const TextStyle(
                fontFamily: 'serif',
                fontSize: 13.5,
                height: 1.7,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppPalette.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.all(12),
              child: Text(
                sentence.translationZh ?? '',
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.8,
                  color: Color(0xFF234534),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (playbackEnabled)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: onPlaySentence,
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('单句朗读'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onPlayContinuous,
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('从此朗读'),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                '译文只在抽屉中展示，原文区不被插入或改动。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

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

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              Icon(icon, size: 19, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.bodyLarge),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
