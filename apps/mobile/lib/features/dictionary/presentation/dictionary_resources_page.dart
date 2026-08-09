import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/scope.dart';
import '../../../contracts/catalog_v1/catalog.dart';
import '../domain/dictionary_models.dart';
import '../infrastructure/dictionary_package_source.dart';

class DictionaryResourcesPage extends StatefulWidget {
  const DictionaryResourcesPage({super.key});

  @override
  State<DictionaryResourcesPage> createState() =>
      _DictionaryResourcesPageState();
}

class _DictionaryResourcesPageState extends State<DictionaryResourcesPage> {
  CatalogDictionary? _candidate;
  String? _error;
  bool _checking = false;
  int _received = 0;
  int? _total;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final catalog = await AppScope.of(context).connection.checkForUpdates();
      if (!mounted) return;
      final matching = catalog.dictionaries
          .where((item) => item.dictionaryId == 'engirdle-en-zh')
          .toList();
      setState(() {
        _candidate = matching.isEmpty ? null : matching.single;
        _error = matching.isEmpty ? '目录中没有可用的正式词典资源。' : null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取资源目录，请检查局域网服务后重试。');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _install(CatalogDictionary candidate) async {
    final deps = AppScope.of(context);
    setState(() {
      _error = null;
      _received = 0;
      _total = candidate.size;
    });
    try {
      await deps.dictionary.install(
        LanDictionaryPackageSource(
          descriptor: DictionaryPackageDescriptor(
            dictionaryId: candidate.dictionaryId,
            revision: candidate.revision,
            formatVersion: candidate.formatVersion,
            schemaVersion: candidate.schemaVersion,
            displayName: candidate.displayName,
            sizeBytes: candidate.size,
            sha256: candidate.sha256,
          ),
          url: candidate.url,
          httpClient: deps.httpClient,
        ),
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _received = received;
              _total = total;
            });
          }
        },
      );
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      if (mounted) setState(() => _error = '词典安装失败，原有词典未受影响；可直接重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dictionary = AppScope.of(context).dictionary;
    return Scaffold(
      appBar: AppBar(title: const Text('词典资源')),
      body: ValueListenableBuilder<DictionaryStatus>(
        valueListenable: dictionary.status,
        builder: (context, status, _) {
          final resource = status.resource ?? dictionary.currentResource();
          return ListView(
            padding: const EdgeInsets.all(14),
            children: [
              _StatusCard(status: status, resource: resource),
              if (status.state == DictionaryResourceState.installing) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _total == null || _total == 0
                      ? null
                      : _received / _total!,
                ),
                const SizedBox(height: 4),
                Text(
                  '正在校验并安装 ${formatBytes(_received)} / '
                  '${_total == null ? 'unknown' : formatBytes(_total!)}',
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed:
                    _checking ||
                        status.state == DictionaryResourceState.installing
                    ? null
                    : _check,
                icon: _checking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: const Text('检查可用资源'),
              ),
              if (_candidate case final candidate?) ...[
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    title: Text(candidate.displayName),
                    subtitle: Text(
                      '${candidate.dictionaryId} · r${candidate.revision} · '
                      '${formatBytes(candidate.size)} · ${_short(candidate.sha256)}',
                    ),
                    trailing: FilledButton(
                      onPressed:
                          status.state == DictionaryResourceState.installing ||
                              (resource != null &&
                                  resource.revision >= candidate.revision)
                          ? null
                          : () => _install(candidate),
                      child: Text(resource == null ? '安装' : '更新'),
                    ),
                  ),
                ),
              ],
              if (resource != null) _ResourceDetails(resource: resource),
            ],
          );
        },
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.resource});
  final DictionaryStatus status;
  final DictionaryResource? resource;

  @override
  Widget build(BuildContext context) {
    final label = switch (status.state) {
      DictionaryResourceState.unavailable => '未安装',
      DictionaryResourceState.installing => '安装中',
      DictionaryResourceState.available => '可用',
      DictionaryResourceState.incompatible => '不兼容',
      DictionaryResourceState.corrupt => '损坏',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              resource == null
                  ? '阅读、翻译、播放和生词本仍可使用，仅离线查词不可用。'
                  : '${resource!.displayName} · ${resource!.dictionaryId} · r${resource!.revision}',
            ),
            if (status.message != null) Text(status.message!),
          ],
        ),
      ),
    );
  }
}

class _ResourceDetails extends StatelessWidget {
  const _ResourceDetails({required this.resource});
  final DictionaryResource resource;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 12),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('资源与归属', style: Theme.of(context).textTheme.titleSmall),
          Text(
            '包：${formatBytes(resource.sizeBytes)} · ${_short(resource.sha256)}',
          ),
          Text(
            '数据库：${formatBytes(resource.databaseSizeBytes)} · '
            '${_short(resource.databaseSha256)}',
          ),
          Text(
            '构建：${resource.builderName} ${resource.builderVersion} · '
            '${resource.generatedAt}',
          ),
          for (final source in resource.sources) ...[
            const Divider(),
            Text('${source.displayName} · ${source.version}'),
            Text('ID：${source.sourceId} · ${source.direction}'),
            Text(
              '词头：原始 ${source.counts.originalHeadwords} · '
              '过滤 ${source.counts.filteredHeadwords} · '
              '最终 ${source.counts.finalHeadwords}',
            ),
            for (final license in source.licenses)
              Text('许可：${license.name} · ${license.url}'),
            for (final attribution in source.attributions)
              Text('归属：${attribution.name} · ${attribution.url}'),
            Text('抽取：${source.extractionNote}'),
          ],
          const Divider(),
          Text('修改：${resource.modifications.join('；')}'),
        ],
      ),
    ),
  );
}

String _short(String value) => value.length <= 12
    ? value
    : '${value.substring(0, 6)}…${value.substring(value.length - 6)}';
