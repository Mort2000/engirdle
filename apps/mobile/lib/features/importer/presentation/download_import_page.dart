import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/scope.dart';
import '../../../app/theme.dart';
import '../../../contracts/catalog_v1/catalog.dart';
import '../../../shared_kernel/failures.dart';
import '../domain/import_models.dart';

/// Screen 04: download progress → integrity check → staged import steps.
///
/// User-facing text exposes only friendly phase names; technical causes
/// (hashes, paths, versions) go to logs (design 假设②).
class DownloadImportPage extends StatefulWidget {
  const DownloadImportPage({required this.package, super.key});

  final CatalogPackage package;

  @override
  State<DownloadImportPage> createState() => _DownloadImportPageState();
}

class _DownloadImportPageState extends State<DownloadImportPage> {
  ImportPhase _phase = ImportPhase.downloading;
  int _received = 0;
  int? _total;
  AppFailure? _failure;
  bool _started = false;

  /// Ordered steps shown under 04B once the download is done.
  static const _steps = [
    ImportPhase.checkingStructure,
    ImportPhase.extracting,
    ImportPhase.validatingContent,
    ImportPhase.validatingReferences,
    ImportPhase.saving,
    ImportPhase.cleaningUp,
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _run();
  }

  Future<void> _run() async {
    final importer = AppScope.of(context).importer;
    try {
      await importer.importPackage(
        widget.package,
        onPhase: (phase) => setState(() => _phase = phase),
        onDownloadProgress: (received, total) => setState(() {
          _received = received;
          _total = total;
        }),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on AppFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    }
  }

  int get _progress {
    final total = _total;
    if (total == null || total <= 0) return 0;
    return ((_received / total) * 100).round().clamp(0, 100);
  }

  _StepState _stepState(ImportPhase step) {
    final currentIndex = _steps.indexOf(_phase);
    final stepIndex = _steps.indexOf(step);
    if (_phase == ImportPhase.downloading ||
        _phase == ImportPhase.verifyingIntegrity) {
      return _StepState.waiting;
    }
    if (stepIndex < currentIndex) return _StepState.done;
    if (stepIndex == currentIndex) return _StepState.active;
    return _StepState.waiting;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloading =
        _phase == ImportPhase.downloading ||
        _phase == ImportPhase.verifyingIntegrity;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(downloading ? '下载文章' : '导入中'),
            Text(
              '${widget.package.title} · 第 ${widget.package.revision} 版',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (downloading) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _phase == ImportPhase.downloading
                          ? '下载中… $_progress%'
                          : '校验完整性…',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 7),
                    LinearProgressIndicator(
                      value: _total == null ? null : _received / _total!,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${formatBytes(_received)} / ${formatBytes(_total ?? widget.package.size)} · 下载完成后会自动校验完整性',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Column(
                  children: [
                    _kv(theme, '大小', formatBytes(widget.package.size)),
                    _kv(theme, '版本', '第 ${widget.package.revision} 版（新）'),
                    _kv(theme, '来源', widget.package.url.host),
                  ],
                ),
              ),
            ),
          ] else ...[
            ..._steps.map(
              (step) => _StepRow(
                label: step.label,
                state: _stepState(step),
                detail: switch (step) {
                  ImportPhase.saving
                      when _stepState(step) == _StepState.active =>
                    '正在保存第 ${widget.package.revision} 版…',
                  ImportPhase.cleaningUp => '完成后将自动清理旧版本',
                  _ => null,
                },
              ),
            ),
            Container(
              margin: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                color: AppPalette.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(12),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 17,
                    color: Color(0xFF234534),
                  ),
                  SizedBox(width: 9),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '失败保护：',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(text: '任一步骤失败都会回滚本次操作；当前已安装的版本与生词不受影响。'),
                        ],
                      ),
                      style: TextStyle(fontSize: 12, color: Color(0xFF234534)),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_failure != null) ...[
            const SizedBox(height: 12),
            Card(
              color: const Color(0xFFFDF3F2),
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 16,
                          color: AppPalette.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            failureKindLabel(_failure!.kind),
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: AppPalette.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      failureMessage(_failure!),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('放弃'),
                ),
                const SizedBox(width: 10),
                FilledButton.tonalIcon(
                  onPressed: () {
                    setState(() {
                      _failure = null;
                      _phase = ImportPhase.downloading;
                      _received = 0;
                    });
                    _run();
                  },
                  icon: const Icon(Icons.refresh, size: 15),
                  label: const Text('重试下载'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(ThemeData theme, String key, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 72,
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
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

enum _StepState { done, active, waiting }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state, this.detail});

  final String label;
  final _StepState state;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, background, foreground) = switch (state) {
      _StepState.done => (Icons.check, AppPalette.okContainer, AppPalette.ok),
      _StepState.active => (
        Icons.sync,
        AppPalette.amberContainer,
        AppPalette.amber,
      ),
      _StepState.waiting => (
        Icons.more_horiz,
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 13, color: foreground),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: state == _StepState.waiting
                        ? theme.colorScheme.onSurfaceVariant
                        : null,
                  ),
                ),
                if (detail != null)
                  Text(detail!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
