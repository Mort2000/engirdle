import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/router.dart';
import '../../../app/scope.dart';
import '../../../app/theme.dart';
import '../../../shared_kernel/content_identity.dart';
import '../../../platform/translation/local_text_translator.dart';
import '../../dictionary/domain/dictionary_models.dart';
import '../../dictionary/presentation/dictionary_sheet.dart';
import '../../library/domain/installed_article.dart';
import '../../playback/domain/playback_models.dart';
import '../../translation/application/translation_module.dart';
import '../../translation/domain/translation_models.dart';
import '../../translation/presentation/translation_messages.dart';
import 'content_block_view.dart';
import 'sentence_view.dart';
import 'sheets.dart';

/// Screens 06/07/08/09/14 — the structured reader.
///
/// Rendering follows the packaged block/sentence structure (never resegmented
/// on device). Inline UI is icon-free: tap = sentence menu (or cancel-first),
/// long-press = word menu; translations and dictionary results always go to
/// bottom drawers.
class ReaderPage extends StatefulWidget {
  const ReaderPage({required this.articleId, super.key});

  final String articleId;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  InstalledContent? _content;
  ReadingMode _mode = ReadingMode.enOnly;
  StreamSubscription<PlaybackEvent>? _playbackEvents;
  StreamSubscription<void>? _libraryEvents;
  StreamSubscription<void>? _translationEvents;

  /// Active translation job of this article, for the status bar (§12.3).
  TranslationJobSnapshot? _activeJob;

  /// sentenceId → 「第 X 段第 Y 句」 display label.
  Map<String, String> _labels = const {};

  /// Cross-sentence selection tracking (constraints §7.3, UX-A4): the
  /// sentence owning the live selection plus the key used to clear it. Only
  /// non-collapsed reports may update these — a tap on sentence B collapses
  /// B's own (empty) selection, so trusting collapsed callbacks would erase
  /// A's record while A's highlight stays on screen.
  String? _selectionSentenceId;
  GlobalKey<SentenceViewState>? _selectionViewKey;

  /// sentenceId → key of its SentenceView; sentence count is bounded by the
  /// article, so a per-sentence GlobalKey is acceptable.
  final Map<String, GlobalKey<SentenceViewState>> _viewKeys = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final deps = AppScope.of(context);
    if (_content != null) return;
    final content = deps.library.getContent(widget.articleId);
    if (content == null) {
      // This method runs inside the first build phase; popping here would
      // setState the Navigator mid-frame, so defer to after the frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return;
    }
    _content = content;
    _mode = deps.library.readingMode(widget.articleId);
    // Safe fallback: a persisted bilingual/zh preference for an article with
    // no active translation set opens en-only instead of empty panes. The
    // stored preference is left alone — a future set re-enables it.
    if (!content.capabilities.hasTranslation && _mode != ReadingMode.enOnly) {
      _mode = ReadingMode.enOnly;
    }
    _labels = content.sentenceLabels;
    for (final sentence in content.sentences) {
      _viewKeys[sentence.sentenceId] = GlobalKey<SentenceViewState>();
    }
    _activeJob = deps.translation.activeJobs()[widget.articleId];
    // Capability refresh (§12.3): activation switches the reader projection
    // without leaving the page; the reading mode itself never auto-switches.
    _libraryEvents = deps.library.changes.listen((_) => _refreshContent());
    _translationEvents = deps.translation.changes.listen((_) {
      if (!mounted) return;
      setState(() {
        _activeJob = AppScope.of(context)
            .translation
            .activeJobs()[widget.articleId];
      });
    });
    // Background playback (design §6.1): leaving the reader no longer stops
    // the session, and app backgrounding no longer pauses it. The page only
    // subscribes to state for highlight and to the continuous-replacement
    // notice; the global host owns the failure toast.
    _playbackEvents = deps.playback.events.listen((event) {
      if (!mounted || event is! ContinuousSessionReplaced) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('「从此开始朗读」已取代上一连续播放会话。')));
    });
  }

  @override
  void dispose() {
    _playbackEvents?.cancel();
    _libraryEvents?.cancel();
    _translationEvents?.cancel();
    super.dispose();
  }

  /// Reloads the projection after a library change (translation activated,
  /// reinstall). The current mode is kept when still valid and falls back to
  /// en-only otherwise; a zh/bilingual preference is never auto-activated.
  void _refreshContent() {
    if (!mounted) return;
    final content = AppScope.of(context).library.getContent(widget.articleId);
    if (content == null) return;
    setState(() {
      _content = content;
      if (!content.capabilities.hasTranslation && _mode != ReadingMode.enOnly) {
        _mode = ReadingMode.enOnly;
      }
    });
  }

  String _labelOf(InstalledSentence sentence) =>
      _labels[sentence.sentenceId] ?? '';

  /// Starts playback from [sentence] in [mode]. The request carries the full
  /// article identity currently displayed; the coordinator resolves the exact
  /// artifact and pins it (design §4.2/§6.3). No lifecycle stop on leave.
  void _startPlayback(InstalledSentence sentence, PlaybackMode mode) {
    final content = _content;
    if (content == null) return;
    AppScope.of(context).playback.start(
      PlaybackRequest(
        articleRef: content.article.ref,
        sentenceId: sentence.sentenceId,
        mode: mode,
      ),
    );
  }

  // ---- Gestures (constraints §7.3, UX-A4) ----

  void _onSentenceTap(InstalledSentence sentence) {
    // Cancel-first: with any open state the tap cancels instead of opening a
    // menu (sheets are modal and absorb taps themselves). The selection owner
    // clears its own visible highlight via the GlobalKey; a page-level flag
    // cannot do that and would leave the highlight behind.
    if (_selectionSentenceId != null) {
      _selectionViewKey?.currentState?.clearSelection();
      _selectionSentenceId = null;
      _selectionViewKey = null;
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SentenceMenuSheet(
        label: _labelOf(sentence),
        translationAvailable: _hasTranslation(),
        translationEnabled: _mode != ReadingMode.zhOnly,
        playbackEnabled: _content?.capabilities.hasNarration ?? false,
        onTranslate: () {
          Navigator.of(sheetContext).pop();
          _showTranslation(sentence);
        },
        onPlaySentence: () {
          Navigator.of(sheetContext).pop();
          _startPlayback(sentence, PlaybackMode.sentence);
        },
        onPlayContinuous: () {
          Navigator.of(sheetContext).pop();
          _startPlayback(sentence, PlaybackMode.continuous);
        },
      ),
    );
  }

  bool _hasTranslation() => _content?.capabilities.hasTranslation ?? false;

  void _showTranslation(InstalledSentence sentence) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SentenceTranslationSheet(
        label: _labelOf(sentence),
        sentence: sentence,
        playbackEnabled: _content?.capabilities.hasNarration ?? false,
        onPlaySentence: () {
          Navigator.of(sheetContext).pop();
          _startPlayback(sentence, PlaybackMode.sentence);
        },
        onPlayContinuous: () {
          Navigator.of(sheetContext).pop();
          _startPlayback(sentence, PlaybackMode.continuous);
        },
      ),
    );
  }

  /// Tracks the selection owner for cancel-first taps. Collapsed reports are
  /// ignored on purpose: they fire at unreliable times (e.g. tapping sentence
  /// B collapses B's empty selection) and must not erase A's record.
  void _onSelectionChanged(InstalledSentence sentence, bool hasSelection) {
    if (!hasSelection) return;
    // One visible selection at a time: a new selection on another sentence
    // clears the previous owner's highlight instead of leaving it stale.
    if (_selectionSentenceId != null &&
        _selectionSentenceId != sentence.sentenceId) {
      _selectionViewKey?.currentState?.clearSelection();
    }
    _selectionSentenceId = sentence.sentenceId;
    _selectionViewKey = _viewKeys[sentence.sentenceId];
  }

  void _onLookup(InstalledSentence sentence, String selection) {
    final deps = AppScope.of(context);
    final lookup = deps.dictionary.lookup(selection);
    final resource = deps.dictionary.currentResource();
    late final DictionaryResult result;
    switch (lookup) {
      case DictionaryLookupUnavailable():
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('未安装词典资源；可在 设置 › 词典资源 安装后使用。'),
            action: SnackBarAction(
              label: '本机翻译',
              onPressed: () => _translateLocally(selection),
            ),
          ),
        );
        return;
      case DictionaryLookupResourceError():
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('词典资源损坏或不可读，请在 设置 › 词典资源 重试安装。'),
            action: SnackBarAction(
              label: '本机翻译',
              onPressed: () => _translateLocally(selection),
            ),
          ),
        );
        return;
      case DictionaryLookupFound(result: final found):
        result = found;
      case DictionaryLookupNotFound(result: final missing):
        result = missing;
    }
    if (resource == null) return;
    final content = _content!;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: FractionallySizedBox(
          heightFactor: 0.8,
          child: DictionarySheet(
            selection: selection,
            result: result,
            resource: resource,
            article: content.article,
            ref: SentenceRef(
              articleId: content.article.articleId,
              revision: content.article.revision,
              sentenceId: sentence.sentenceId,
            ),
            sentenceText: sentence.text,
            sentenceTranslationZh: sentence.translationZh,
            vocabulary: deps.vocabulary,
            onTranslateLocally: () => _translateLocally(selection),
          ),
        ),
      ),
    );
  }

  Future<void> _translateLocally(String selection) async {
    try {
      final result = await AppScope.of(
        context,
      ).localTextTranslator.translate(selection);
      if (!mounted || result == LocalTranslationResult.opened) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未找到可处理所选文本的本机翻译应用。')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开本机翻译应用。')));
    }
  }

  void _setMode(ReadingMode mode) {
    setState(() => _mode = mode);
    // Mode is per-article persisted; content data and playback untouched.
    AppScope.of(context).library.setReadingMode(widget.articleId, mode);
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final content = _content;
    if (content == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final deps = AppScope.of(context);
    final prefs = deps.preferences.notifier.value;
    final palette = PaletteScope.of(context);
    final theme = Theme.of(context);

    final serif = prefs.fontFamily.name == 'serif';
    final textStyle = TextStyle(
      fontFamily: serif ? 'serif' : null,
      fontSize: prefs.fontSize.logicalPixels,
      height: prefs.lineHeight.factor,
      color: palette.ink,
    );
    final zhStyle = TextStyle(
      fontSize: prefs.fontSize.logicalPixels - 2,
      height: 1.7,
      color: palette.inkVariant,
    );

    return Scaffold(
      backgroundColor: palette.paper,
      appBar: AppBar(
        backgroundColor: palette.paper,
        title: Text(
          _mode == ReadingMode.zhOnly
              ? _zhTitleFallback(content.article.title)
              : content.article.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          _ModeChip(
            mode: _mode,
            translationEnabled: content.capabilities.hasTranslation,
            onChanged: _setMode,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'typography':
                  Navigator.of(context).pushNamed(AppRoutes.typography);
                case 'playback':
                  Navigator.of(context).pushNamed(AppRoutes.playbackSettings);
                case 'attribution':
                  Navigator.of(context).pushNamed(
                    AppRoutes.attribution,
                    arguments: widget.articleId,
                  );
                case 'dictionary':
                  Navigator.of(
                    context,
                  ).pushNamed(AppRoutes.dictionaryResources);
                case 'translate':
                  _startTranslateFlow();
                case 'task':
                  final job = _activeJob ??
                      AppScope.of(context)
                          .translation
                          .latestJobForArticle(widget.articleId);
                  if (job != null) {
                    Navigator.of(context).pushNamed(
                      AppRoutes.translationTask,
                      arguments: job.jobId,
                    );
                  }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'typography',
                child: Text('排版与主题'),
              ),
              const PopupMenuItem(
                value: 'playback',
                child: Text('播放设置'),
              ),
              const PopupMenuItem(
                value: 'attribution',
                child: Text('归属信息'),
              ),
              const PopupMenuItem(
                value: 'dictionary',
                child: Text('词典资源'),
              ),
              // Only without an active complete set: the whole point of the
              // lightweight path is making translation optional (§12.3).
              if (!content.capabilities.hasTranslation &&
                  _activeJob == null) ...[
                const PopupMenuItem(
                  value: 'translate',
                  child: Text('翻译文章'),
                ),
              ],
              if (_activeJob != null)
                const PopupMenuItem(
                  value: 'task',
                  child: Text('翻译任务'),
                ),
            ],
          ),
        ],
      ),
      body: ValueListenableBuilder<PlaybackSnapshot>(
        valueListenable: deps.playback.state,
        builder: (context, playbackState, _) {
          return ListView(
            padding: EdgeInsets.fromLTRB(
              prefs.margin.logicalPixels,
              8,
              prefs.margin.logicalPixels,
              24,
            ),
            children: [
              if (_activeJob != null)
                _TranslationStatusBar(job: _activeJob!),
              _Header(
                content: content,
                mode: _mode,
                theme: theme,
                zhTitle: _zhTitleFallback(content.article.title),
              ),
              for (final block in content.blocks)
                ContentBlockView(
                  block: block,
                  mode: _mode,
                  textStyle: textStyle,
                  zhStyle: zhStyle,
                  currentSentenceId: playbackState.currentSentenceId,
                  viewKeys: _viewKeys,
                  onSentenceTap: _onSentenceTap,
                  onLookup: _onLookup,
                  onTranslate: (_, selection) => _translateLocally(selection),
                  onSelectionChanged: _onSelectionChanged,
                  onZhLongPress: () =>
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请切换到仅英文或英中对照模式选词')),
                      ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// zh-only shows the translated title when we don't have one we fall back
  /// to the original (title translation is not part of readpack v1).
  String _zhTitleFallback(String title) => title;

  /// Constraint line for the confirmation dialog (§8.6: 确认页展示网络约束).
  /// Shows the same profile values that queueTranslation freezes into the
  /// job's config snapshot.
  String _constraintText(LlmProfile? profile) {
    final wifi = profile?.wifiOnly ?? false;
    final charging = profile?.chargingOnly ?? false;
    if (wifi && charging) return '仅 Wi-Fi 且仅充电时执行';
    if (wifi) return '仅 Wi-Fi 时执行';
    if (charging) return '仅充电时执行';
    return '任意可用网络';
  }

  /// 翻译确认流（§8.6/§10.2）：隐私声明、保守估算与配置快照都在开始前
  /// 明确展示；全文发送的确认时间会记录在任务上。
  Future<void> _startTranslateFlow() async {
    final deps = AppScope.of(context);
    final module = deps.translation;
    final latest = module.latestJobForArticle(widget.articleId);
    if (latest != null && latest.status == TranslationJobStatus.failed) {
      final retry = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('继续翻译这篇文章？'),
          content: Text(
            '上次的翻译在第 ${latest.completedUnits}/${latest.totalUnits} 个单元'
            '停止；重试会从上次进度继续，不会重复已完成的单元。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
      if (retry == true) module.retry(latest.jobId);
      return;
    }
    final TranslationEstimate estimate;
    try {
      estimate = module.estimate(widget.articleId);
    } on TranslationQueueRefusal catch (refusal) {
      _snack(translationRefusalText(refusal));
      return;
    }
    final profile = AppScope.of(context).translationSettings.profile();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('翻译这篇文章？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${estimate.articleChars} 字符 · ${estimate.sentenceCount} 句 · '
              '${estimate.tableCount} 个表格，共 ${estimate.unitCount} 个翻译单元。',
            ),
            const SizedBox(height: 8),
            Text(
              '预计输入约 ${formatThousands(estimate.minInputTokens)}–'
              '${formatThousands(estimate.maxInputTokens)} tokens'
              '（按完整历史回放保守估算，仅供参考，非费用承诺）。',
            ),
            const SizedBox(height: 8),
            Text('服务商：DeepSeek（${profile?.model ?? 'deepseek-v4-flash'}）'),
            const SizedBox(height: 8),
            Text('网络要求：${_constraintText(profile)}'),
            const SizedBox(height: 8),
            const Text(
              '开始后，文章全文将发送到 DeepSeek 官方服务进行翻译；'
              '你的 API Key 仅用于本次请求。',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始翻译'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // §9.3: best-effort POST_NOTIFICATIONS ask right before the first
    // background run; denial never blocks translation.
    unawaited(deps.translationNotificationPrompt.requestIfNeeded());
    try {
      await module.queueTranslation(
        articleId: widget.articleId,
        privacyConfirmedAt: DateTime.now(),
      );
      _snack('翻译任务已开始；阅读不受影响。');
    } on TranslationQueueRefusal catch (refusal) {
      _snack(translationRefusalText(refusal));
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 小型非阻塞状态条（§12.3）：正文上方展示任务进度，点击查看任务详情；
/// 阅读不被锁住。
class _TranslationStatusBar extends StatelessWidget {
  const _TranslationStatusBar({required this.job});

  final TranslationJobSnapshot job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.of(context).pushNamed(
          AppRoutes.translationTask,
          arguments: job.jobId,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppPalette.amberContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  translationProgressLabel(job),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.amber,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '查看',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.amber,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.content,
    required this.mode,
    required this.theme,
    required this.zhTitle,
  });

  final InstalledContent content;
  final ReadingMode mode;
  final ThemeData theme;
  final String zhTitle;

  @override
  Widget build(BuildContext context) {
    final article = content.article;
    final wordCount = formatThousands(content.approximateWordCount);
    final narrationMeta = article.narration == null
        ? '仅原文'
        : '句级语音 ${_duration(article.narration!.durationMs)}';
    final meta = switch (mode) {
      ReadingMode.enOnly =>
        '${article.author ?? '未知作者'} · 约 $wordCount 词 · $narrationMeta',
      ReadingMode.bilingual =>
        '${article.author ?? '未知作者'} · 约 $wordCount 词 · $narrationMeta',
      ReadingMode.zhOnly =>
        '${article.author ?? '未知作者'} · 第 ${article.revision} 版 · 句级语音为英文原文',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          mode == ReadingMode.zhOnly ? zhTitle : article.title,
          style: TextStyle(
            fontFamily: 'serif',
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: PaletteScope.of(context).ink,
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(meta, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }

  static String _duration(int ms) {
    final totalSeconds = ms ~/ 1000;
    return '${totalSeconds ~/ 60}:${(totalSeconds % 60).toString().padLeft(2, '0')}';
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.mode,
    required this.translationEnabled,
    required this.onChanged,
  });

  final ReadingMode mode;

  /// Without an active translation set the bilingual/zh entries are hidden
  /// (not disabled): the article simply has no such reading mode yet.
  final bool translationEnabled;

  final void Function(ReadingMode) onChanged;

  static const _labels = {
    ReadingMode.enOnly: '仅英文',
    ReadingMode.bilingual: '英中对照',
    ReadingMode.zhOnly: '仅中文',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<ReadingMode>(
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final entry in _labels.entries)
          if (entry.key == ReadingMode.enOnly || translationEnabled)
            PopupMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.translate,
              size: 11,
              color: theme.colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 4),
            Text(
              '${_labels[mode]} ▾',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
