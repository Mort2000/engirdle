import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/scope.dart';
import '../../../contracts/readpack_v1/attribution.dart';

/// Screen 15 — attribution & dictionary resource info (NFR-LIC-001).
///
/// Read-only display of the package's provenance chain and the independently
/// versioned dictionary resource. Unknown/n-a fields are shown explicitly.
class AttributionPage extends StatelessWidget {
  const AttributionPage({required this.articleId, super.key});

  final String articleId;

  @override
  Widget build(BuildContext context) {
    final deps = AppScope.of(context);
    final theme = Theme.of(context);
    final article = deps.library.getArticle(articleId);
    final parsed = deps.attribution.articleAttribution(articleId);
    final dictionary = deps.attribution.dictionaryResource();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('归属与许可'),
            Text('入口：书架 / 阅读器溢出菜单 › 归属信息', style: theme.textTheme.labelSmall),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (article != null && parsed != null) ...[
            _Section(
              title: '文章',
              rows: [
                ('标题', article.title),
                (
                  '作者 / 来源',
                  '${article.author ?? 'unknown'} · ${article.sourceDisplayName ?? 'n/a'}',
                ),
                ('许可', _articleLicense(parsed.attribution)),
                (
                  '版本',
                  'rev ${article.revision} · 制品 r${article.artifactRevision} · package ${_short(article.packageId)}',
                ),
              ],
            ),
            _Section(
              title: '翻译服务',
              rows: [
                (
                  '提供方 / 模型',
                  '${parsed.manifest.pipeline.translationProvider} · ${parsed.manifest.pipeline.translationModel}',
                ),
                (
                  '配置',
                  'thinking ${parsed.manifest.pipeline.translationThinking} · effort ${parsed.manifest.pipeline.translationReasoningEffort}',
                ),
                ('提示词版本', parsed.manifest.pipeline.translationPrompt),
              ],
            ),
            _Section(
              title: '语音合成（PC 本地）',
              rows: [
                ('合成模型', parsed.manifest.pipeline.ttsBaseModel),
                ('锚点模型', parsed.manifest.pipeline.ttsCustomVoiceModel),
                (
                  '声音配置',
                  '${parsed.manifest.pipeline.voiceProfile} · anchor ${_short(parsed.manifest.pipeline.anchorSha256)}',
                ),
                if (article.narration != null)
                  (
                    '音频',
                    '${article.narration!.codec.toUpperCase()} · '
                        '${article.narration!.sampleRateHz ~/ 1000} kHz · '
                        '${article.narration!.channels == 1 ? '单声道' : '${article.narration!.channels} 声道'} · '
                        '${formatDurationMs(article.narration!.durationMs)}',
                  ),
              ],
            ),
          ],
          _Section(
            title: '词典资源',
            rows: dictionary == null
                ? const [('状态', '未安装 · 阅读 / 翻译 / 播放不受影响')]
                : [
                    (
                      'ID / 修订',
                      '${dictionary.dictionaryId} · r${dictionary.revision}',
                    ),
                    (
                      '大小 / SHA-256',
                      '${formatBytes(dictionary.sizeBytes)} · ${_short(dictionary.sha256)}',
                    ),
                    for (var i = 0; i < dictionary.sources.length; i++)
                      (
                        '数据源${dictionary.sources.length > 1 ? ' ${i + 1}' : ''}',
                        '${dictionary.sources[i].displayName} ${dictionary.sources[i].version} · '
                            '${dictionary.sources[i].licenses.map((license) => license.name).join(' / ')}',
                      ),
                    ('修改说明', dictionary.modifications.join('；')),
                  ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '未知或不适用字段显式标记为 unknown / n/a；词典独立于文章包安装与升级。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  static String _articleLicense(ReadpackAttribution attribution) {
    for (final resource in attribution.resources) {
      if (resource.kind == 'article_source') {
        return resource.license.display;
      }
    }
    return 'unknown';
  }

  static String _short(String? value) {
    if (value == null) return '—';
    return value.length <= 8
        ? value
        : '${value.substring(0, 4)}…${value.substring(value.length - 4)}';
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 3),
            for (final (key, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        key,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        value,
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
