import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/scope.dart';
import '../../../app/theme.dart';

/// Screen 16: the connection policy as a user-visible page — local-first,
/// offline by default (NFR-OFF-001).
class ConnectionOfflinePage extends StatelessWidget {
  const ConnectionOfflinePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final endpoint = AppScope.of(context).connection.current();
    final lastCheck = endpoint?.lastCatalogCheckAt;
    return Scaffold(
      appBar: AppBar(title: const Text('连接与离线')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Card(
            color: AppPalette.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.cloud_off_outlined,
                        size: 17, color: theme.colorScheme.onPrimaryContainer),
                    const SizedBox(width: 6),
                    Text('本地优先 · 默认离线',
                        style: theme.textTheme.titleSmall),
                  ]),
                  const SizedBox(height: 5),
                  const Text(
                    '应用从不后台连接、不轮询目录。无论飞行模式、移动网络还是 Wi-Fi，只有你主动操作时才会联网。',
                    style: TextStyle(fontSize: 12.5),
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
                  Text('会联网的操作（均需你手动触发）',
                      style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  _kv(theme, '验证 / 保存服务地址', '服务设置 · 手动点「验证连接」'),
                  _kv(theme, '检查更新与下载', '书架「检查更新」按钮'),
                  _kv(theme, '上次检查更新',
                      lastCheck == null ? '从未' : formatRelative(lastCheck)),
                  _kv(theme, '后台连接 / 自动同步', '不存在',
                      valueColor: theme.colorScheme.error),
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
                  Text('永远离线可用的功能', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: const [
                      _OfflineChip('阅读'),
                      _OfflineChip('三种译文模式'),
                      _OfflineChip('句级 / 连续播放'),
                      _OfflineChip('离线查词'),
                      _OfflineChip('生词增删'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '文章、音频、词典与生词全部保存在本机；飞行模式只是充分条件，不是前提。',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(ThemeData theme, String key, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(key,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(
                color: valueColor,
                fontWeight:
                    valueColor != null ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OfflineChip extends StatelessWidget {
  const _OfflineChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppPalette.okContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check, size: 12, color: AppPalette.ok),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.ok)),
        ],
      ),
    );
  }
}
