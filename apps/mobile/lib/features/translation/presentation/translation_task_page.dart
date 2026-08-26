import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/scope.dart';
import '../../../app/theme.dart';
import '../application/translation_module.dart';
import '../domain/translation_models.dart';

/// 任务详情（design §12.4）：状态、进度、时间、模型、可操作错误与
/// 暂停/继续/取消/同配置重试。不展示任何正文或译文。
class TranslationTaskPage extends StatefulWidget {
  const TranslationTaskPage({required this.jobId, super.key});

  final String jobId;

  @override
  State<TranslationTaskPage> createState() => _TranslationTaskPageState();
}

class _TranslationTaskPageState extends State<TranslationTaskPage> {
  StreamSubscription<void>? _sub;

  TranslationModule get _module => AppScope.of(context).translation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub ??= _module.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final job = _module.jobById(widget.jobId);
    if (job == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final progress = job.totalUnits == 0
        ? 0.0
        : job.completedUnits / job.totalUnits;

    return Scaffold(
      appBar: AppBar(title: const Text('翻译任务')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _statusText(job),
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: _statusColor(job.status, theme),
                          ),
                        ),
                      ),
                      Text(
                        '${job.completedUnits}/${job.totalUnits} 单元',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 12),
                  _row('模型', job.config.model),
                  _row('目标语言', job.targetLocale),
                  if (job.startedAt != null)
                    _row('开始于', formatDate(job.startedAt!)),
                  _row('更新于', formatDate(job.updatedAt)),
                  if (job.finishedAt != null)
                    _row('结束于', formatDate(job.finishedAt!)),
                  if (job.status == TranslationJobStatus.waitingRetry)
                    _row('重试轮次', '第 ${job.retryRound} 轮'),
                ],
              ),
            ),
          ),
          if (job.errorKind != null &&
              (job.status == TranslationJobStatus.failed ||
                  job.status == TranslationJobStatus.waitingRetry))
            Card(
              color: AppPalette.amberContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('出了什么问题', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(_errorText(job), style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            ),
          _actions(job),
          const SizedBox(height: 8),
          Text(
            '原文始终可以阅读；翻译失败或取消不影响已保存的内容与生词。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );

  Widget _actions(TranslationJobSnapshot job) {
    final module = _module;
    switch (job.status) {
      case TranslationJobStatus.queued:
      case TranslationJobStatus.running:
      case TranslationJobStatus.waitingRetry:
        return Card(
          child: OverflowBar(
            children: [
              OutlinedButton(
                onPressed: () => module.pause(job.jobId),
                child: const Text('暂停'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.error,
                ),
                onPressed: () => module.cancel(job.jobId),
                child: const Text('取消任务'),
              ),
            ],
          ),
        );
      case TranslationJobStatus.paused:
        return Card(
          child: OverflowBar(
            children: [
              FilledButton(
                onPressed: () => module.resume(job.jobId),
                child: const Text('继续'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.error,
                ),
                onPressed: () => module.cancel(job.jobId),
                child: const Text('取消任务'),
              ),
            ],
          ),
        );
      case TranslationJobStatus.failed:
        return Card(
          child: OverflowBar(
            children: [
              FilledButton(
                onPressed: () => module.retry(job.jobId),
                child: const Text('同配置重试'),
              ),
            ],
          ),
        );
      case TranslationJobStatus.completed:
      case TranslationJobStatus.cancelled:
        return const SizedBox.shrink();
    }
  }

  static String _statusText(TranslationJobSnapshot job) =>
      switch (job.status) {
        TranslationJobStatus.queued => '排队中',
        TranslationJobStatus.running => '翻译中',
        TranslationJobStatus.waitingRetry => '等待重试',
        TranslationJobStatus.paused => '已暂停',
        TranslationJobStatus.failed => '失败',
        TranslationJobStatus.completed => '已完成',
        TranslationJobStatus.cancelled =>
          job.errorKind == TranslationErrorKind.staleSource
              ? '已取消（原文已变更）'
              : '已取消',
      };

  static Color _statusColor(TranslationJobStatus status, ThemeData theme) =>
      switch (status) {
        TranslationJobStatus.completed => AppPalette.ok,
        TranslationJobStatus.failed => theme.colorScheme.error,
        TranslationJobStatus.cancelled => theme.hintColor,
        _ => AppPalette.amber,
      };

  static String _errorText(TranslationJobSnapshot job) =>
      switch (job.errorKind) {
        TranslationErrorKind.auth => 'API Key 无效或未配置。请到 设置 › 翻译服务 '
            '重新填写后再重试。',
        TranslationErrorKind.balance => 'DeepSeek 账户余额不足。充值后可从上次的'
            '进度继续重试。',
        TranslationErrorKind.contextLimit => '文章（含翻译历史回放）超出模型上下文'
            '上限，当前无法翻译这么长的文章。',
        TranslationErrorKind.transport => '网络或服务在多轮重试后仍不可用。恢复网络'
            '后可从上次的进度继续重试。',
        TranslationErrorKind.protocol => '模型响应反复不符合协议格式，任务已停止。'
            '可稍后重试。',
        TranslationErrorKind.config => '翻译配置不可用，请到 设置 › 翻译服务 检查。',
        TranslationErrorKind.staleSource => '原文已重新导入或删除，本任务已取消，'
            '不会激活过期译文。',
        TranslationErrorKind.internal => '翻译过程中出现内部错误，任务已停止。'
            '可稍后重试。',
        null => '任务已停止。',
      };
}
