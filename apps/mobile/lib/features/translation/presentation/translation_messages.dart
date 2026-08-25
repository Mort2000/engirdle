import '../application/translation_module.dart';
import '../domain/translation_models.dart';

/// User-facing text for queue-time refusals (§8.5/§8.6): actionable, without
/// engineering detail.
String translationRefusalText(TranslationQueueRefusal refusal) =>
    switch (refusal.kind) {
      TranslationErrorKind.auth => '尚未保存 DeepSeek API Key。请先到 设置 › 翻译服务 '
          '填写密钥。',
      TranslationErrorKind.balance => 'DeepSeek 账户余额不足。',
      TranslationErrorKind.contextLimit => '文章（含翻译历史回放）预计超出模型上下'
          '文上限，暂不开始翻译。',
      TranslationErrorKind.staleSource => '文章不存在或已变更，请重新打开后再试。',
      TranslationErrorKind.config => refusal.message,
      _ => refusal.message,
    };

/// Short progress label for the reader status bar and the bookshelf badge.
String translationProgressLabel(TranslationJobSnapshot job) => switch (
  job.status
) {
  TranslationJobStatus.running => '翻译中 ${job.completedUnits}/${job.totalUnits}',
  TranslationJobStatus.queued => '翻译排队中',
  TranslationJobStatus.waitingRetry => '翻译等待重试',
  TranslationJobStatus.paused => '翻译已暂停',
  _ => '翻译 ${job.completedUnits}/${job.totalUnits}',
};
