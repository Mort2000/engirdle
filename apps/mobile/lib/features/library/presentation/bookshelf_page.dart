import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/router.dart';
import '../../../app/scope.dart';
import '../../../app/dependencies.dart';
import '../../../app/theme.dart';
import '../../../shared_kernel/failures.dart';
import '../../catalog/domain/catalog_status.dart';
import '../../connection/presentation/service_setup_page.dart';
import '../../importer/presentation/download_import_page.dart';
import '../../source_ingestion/presentation/source_confirm_page.dart';
import '../../translation/domain/translation_models.dart';
import '../../translation/presentation/translation_messages.dart';
import '../domain/installed_article.dart';
import 'widgets/article_cover.dart';

/// Screens 03 / 05 / 17A — the bookshelf is the home page.
///
/// Default view is strictly local (no background connections, no polling).
/// Tapping「检查更新」fetches the catalog once; the result is session-scoped
/// and never cached on disk — leaving the page returns to the local view.
class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  List<InstalledArticle> _articles = const [];
  String? _resumableImport; // journaled preview awaiting confirmation
  List<CatalogEntry>? _catalog; // null = local-only view (03A)
  String? _catalogError;
  bool _checking = false;
  bool _loaded = false;
  bool _firstRunChecked = false;
  StreamSubscription<void>? _translationEvents;

  /// articleId → active job (translation progress badges, §12.1).
  Map<String, TranslationJobSnapshot> _activeJobs = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFirstRun());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // AppScope is an InheritedWidget; reading it in initState throws, so the
    // first load waits for dependencies (guarded against re-entry).
    if (_loaded) return;
    _loaded = true;
    _reload();
    _translationEvents = AppScope.of(context).translation.changes.listen((_) {
      if (mounted) _reloadBadges();
    });
  }

  @override
  void dispose() {
    _translationEvents?.cancel();
    super.dispose();
  }

  void _reloadBadges() {
    setState(() {
      _activeJobs = AppScope.of(context).translation.activeJobs();
    });
  }

  void _reload() {
    if (!mounted) return;
    final deps = AppScope.of(context);
    setState(() {
      _articles = deps.library.listArticles();
      _activeJobs = deps.translation.activeJobs();
      // §6.5/§14.4: a preview frozen before process death resumes here.
      _resumableImport = deps.contentImport
          .pendingPreviews()
          .firstOrNull
          ?.importId;
    });
  }

  Future<void> _resumePendingImport() async {
    final importId = _resumableImport;
    if (importId == null) return;
    final deps = AppScope.of(context);
    try {
      final preview = await deps.contentImport.resumePreview(importId);
      if (!mounted) return;
      final installed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => SourceConfirmPage(preview: preview)),
      );
      if (installed == true) _reload();
    } on AppFailure {
      _reload();
    }
  }

  void _maybeFirstRun() {
    if (_firstRunChecked) return;
    _firstRunChecked = true;
    final endpoint = AppScope.of(context).connection.current();
    if (endpoint == null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const ServiceSetupPage(isFirstRun: true),
        ),
      );
    }
  }

  Future<void> _checkUpdates() async {
    // In-flight guard: the empty-shelf guidance button (17A) stays enabled
    // while checking, so re-entry must be stopped here.
    if (_checking) return;
    final deps = AppScope.of(context);
    final endpoint = deps.connection.current();
    if (endpoint == null) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const ServiceSetupPage()));
      _reload();
      return;
    }
    if (endpoint.verifiedAt == null) {
      // Saved but never verified (design 假设⑦): a successful check doubles
      // as the first verification — say so before connecting.
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该地址尚未验证，正在尝试验证并获取目录。')));
    }
    setState(() {
      _checking = true;
      _catalogError = null;
    });
    try {
      final entries = await deps.catalog.checkForUpdates();
      if (!mounted) return;
      setState(() => _catalog = entries);
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() => _catalogError = failureMessage(failure));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openReader(InstalledArticle article) async {
    await Navigator.of(
      context,
    ).pushNamed(AppRoutes.reader, arguments: article.articleId);
    _reload();
  }

  Future<void> _download(CatalogEntry entry) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DownloadImportPage(package: entry.package),
      ),
    );
    if (changed == true) {
      _reload();
      // The fresh install may satisfy a pending update badge.
      setState(() => _catalog = null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('《${entry.package.title}》已保存到本机，可离线使用。')),
        );
      }
    }
  }

  Future<void> _importContent() async {
    final deps = AppScope.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 14, bottom: 6),
              child: Text('导入文章'),
            ),
            // 粘贴原文 first (design §12.1).
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('粘贴原文'),
              subtitle: const Text('直接粘贴文本，选择纯文本或 Markdown'),
              onTap: () => Navigator.of(sheetContext).pop('paste'),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('选择原文文件'),
              subtitle: const Text('.txt / .md / .markdown'),
              onTap: () => Navigator.of(sheetContext).pop('file'),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('选择文章包'),
              subtitle: const Text('.readpack（v1 与 v2）'),
              onTap: () => Navigator.of(sheetContext).pop('package'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'paste':
        final changed = await Navigator.of(
          context,
        ).pushNamed(AppRoutes.pasteSource);
        if (changed == true) _reload();
      case 'file':
        await _pickSourceFile(deps);
      case 'package':
        await _pickPackage(deps);
    }
  }

  Future<void> _pickSourceFile(AppDependencies deps) async {
    final picked = await deps.documentPicker.pickDocument();
    if (picked == null || !mounted) return;
    final name = picked.displayName ?? '';
    try {
      final preview = await deps.contentImport.stageDocumentSource(
        rawBytes: picked.bytes,
        fileName: name,
      );
      if (!mounted) return;
      final installed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => SourceConfirmPage(preview: preview)),
      );
      if (installed == true) _reload();
    } on AppFailure catch (failure) {
      _snack('导入失败：${failureMessage(failure)}');
    }
  }

  Future<void> _pickPackage(AppDependencies deps) async {
    final picked = await deps.documentPicker.pickDocument();
    if (picked == null || !mounted) return;
    final name = picked.displayName ?? '';
    if (!name.toLowerCase().endsWith('.readpack')) {
      _snack('不支持的文件类型「$name」；请选择 .readpack 文章包。');
      return;
    }
    try {
      await deps.contentImport.importDocumentPackage(
        bytes: picked.bytes,
        fileName: name,
      );
      _reload();
      _snack('文章包已导入本机，可离线使用。');
    } on AppFailure catch (failure) {
      _snack('导入失败：${failureMessage(failure)}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmDelete(InstalledArticle article) async {
    final deps = AppScope.of(context);
    final vocabCount = deps.vocabulary.countForArticle(article.articleId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: AppPalette.error),
        title: const Text('删除这篇文章？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('将删除本机《${article.title}》的文章文本与音频。'),
            const SizedBox(height: 8),
            Text(
              vocabCount > 0
                  ? '生词保留策略：生词本中引用本文的 $vocabCount 条生词已保存原句与释义内容，删除文章后仍可完整查看。'
                  : '生词本中没有引用本文的生词。',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '此操作不影响 PC 端已发布内容；如需再次阅读，可在书架点「检查更新」后重新下载。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppPalette.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      // Stop and release any active session on this article before deleting,
      // so the lease guard never has to refuse (design §6.3).
      await deps.playback.stopIfActive(article.articleId);
      await deps.library.deleteArticle(article.articleId);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = AppScope.of(context);
    final endpoint = deps.connection.current();
    final theme = Theme.of(context);
    final catalogActive = _catalog != null;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('书架'),
            Text(
              catalogActive
                  ? '刚刚检查 · ${endpoint == null ? '' : '${endpoint.baseUrl.host}:${endpoint.baseUrl.port}'}'
                  : '本地 ${_articles.length} 篇 · 默认离线，不自动连接',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'vocab':
                  Navigator.of(context).pushNamed(AppRoutes.vocabulary);
                case 'typography':
                  Navigator.of(context).pushNamed(AppRoutes.typography);
                case 'playback':
                  Navigator.of(context).pushNamed(AppRoutes.playbackSettings);
                case 'offline':
                  Navigator.of(context).pushNamed(AppRoutes.connectionOffline);
                case 'service':
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ServiceSetupPage(),
                    ),
                  );
                case 'dictionary':
                  Navigator.of(
                    context,
                  ).pushNamed(AppRoutes.dictionaryResources);
                case 'translation':
                  Navigator.of(
                    context,
                  ).pushNamed(AppRoutes.translationSettings);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'vocab', child: Text('生词本')),
              PopupMenuItem(value: 'typography', child: Text('排版与主题')),
              PopupMenuItem(value: 'playback', child: Text('播放设置')),
              PopupMenuItem(value: 'offline', child: Text('连接与离线')),
              PopupMenuItem(value: 'service', child: Text('服务设置')),
              PopupMenuItem(value: 'dictionary', child: Text('词典资源')),
              PopupMenuItem(value: 'translation', child: Text('翻译服务')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importContent,
        icon: const Icon(Icons.add),
        label: const Text('导入'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 88),
        children: [
          if (_resumableImport != null)
            Card(
              color: AppPalette.amberContainer,
              child: ListTile(
                leading: const Icon(Icons.history),
                title: const Text('有一次未确认的导入预览'),
                subtitle: const Text('上次预览后应用被中断；可继续确认或忽略。'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _resumePendingImport,
              ),
            ),
          _RefreshCard(
            checking: _checking,
            catalogActive: catalogActive,
            lastCheck: endpoint?.lastCatalogCheckAt,
            error: _catalogError,
            onCheck: _checkUpdates,
          ),
          const SizedBox(height: 6),
          if (_articles.isEmpty && !catalogActive)
            _EmptyShelf(hasEndpoint: endpoint != null, onCheck: _checkUpdates)
          else if (catalogActive)
            ..._catalog!.map(
              (entry) => _CatalogTile(
                entry: entry,
                local: _articles
                    .where((a) => a.articleId == entry.package.articleId)
                    .firstOrNull,
                onOpen: _openReader,
                onDownload: () => _download(entry),
              ),
            )
          else
            ..._articles.map(
              (article) => _ArticleTile(
                article: article,
                activeJob: _activeJobs[article.articleId],
                onOpen: () => _openReader(article),
                onDelete: () => _confirmDelete(article),
                onAttribution: () => Navigator.of(context).pushNamed(
                  AppRoutes.attribution,
                  arguments: article.articleId,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            catalogActive
                ? '目录结果仅在手动刷新后展示，应用不后台轮询。'
                : '未刷新时不显示任何「有新版本」信息；阅读、播放、查词、生词全部离线可用。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _RefreshCard extends StatelessWidget {
  const _RefreshCard({
    required this.checking,
    required this.catalogActive,
    required this.lastCheck,
    required this.error,
    required this.onCheck,
  });

  final bool checking;
  final bool catalogActive;
  final DateTime? lastCheck;
  final String? error;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: catalogActive ? AppPalette.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                FilledButton.icon(
                  onPressed: checking ? null : onCheck,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(
                    catalogActive
                        ? (checking ? '检查中…' : '再检查')
                        : (checking ? '检查中…' : '检查更新'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    catalogActive
                        ? '上次检查：刚刚 · 目录已获取\n结果不缓存展示，下次打开仍是本机视图'
                        : '上次检查：${lastCheck == null ? '从未' : formatRelative(lastCheck!)}\n只有点击后才会连接 PC 服务',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                '无法获取目录：$error\n列表保持本机内容不变，不影响离线使用。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ArticleTile extends StatelessWidget {
  const _ArticleTile({
    required this.article,
    required this.onOpen,
    required this.onDelete,
    required this.onAttribution,
    this.activeJob,
  });

  final InstalledArticle article;

  /// Active translation job (翻译中 badge); an existing complete set keeps
  /// showing 已翻译 while a retry runs (§12.1).
  final TranslationJobSnapshot? activeJob;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final VoidCallback onAttribution;

  Widget _badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: AppPalette.okContainer,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        color: AppPalette.ok,
      ),
    ),
  );

  Widget _progressBadge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: AppPalette.amberContainer,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        color: AppPalette.amber,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(
          children: [
            ArticleCover(title: article.title, articleId: article.articleId),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    article.narration == null
                        ? '${article.author ?? '未知作者'} · 仅原文'
                        : '${article.author ?? '未知作者'} · 音频 ${formatDurationMs(article.narration!.durationMs)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (activeJob != null) ...[
                  _progressBadge(translationProgressLabel(activeJob!)),
                  const SizedBox(height: 4),
                ],
                if (article.hasTranslation) _badge('已翻译'),
                if (article.narration != null) ...[
                  const SizedBox(height: 4),
                  _badge('含语音'),
                ],
                if (!article.hasTranslation &&
                    article.narration == null &&
                    activeJob == null)
                  _badge('原文'),
              ],
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'attribution') onAttribution();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'attribution', child: Text('归属信息')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.entry,
    required this.local,
    required this.onOpen,
    required this.onDownload,
  });

  final CatalogEntry entry;
  final InstalledArticle? local;
  final void Function(InstalledArticle) onOpen;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final package = entry.package;
    final installed = local;
    return InkWell(
      onTap: installed == null ? null : () => onOpen(installed),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(
          children: [
            ArticleCover(title: package.title, articleId: package.articleId),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    package.title,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    // 03B: package size is engineering detail — it belongs to
                    // the download page (04), not the list subtitle.
                    installed != null
                        ? installed.narration == null
                              ? '${installed.author ?? '未知作者'} · 仅原文'
                              : '${installed.author ?? '未知作者'} · 音频 ${formatDurationMs(installed.narration!.durationMs)}'
                        : '未安装',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            switch (entry.status) {
              CatalogEntryStatus.updateAvailable => Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _badge('有更新', AppPalette.amberContainer, AppPalette.amber),
                  const SizedBox(height: 6),
                  FilledButton.tonalIcon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download, size: 14),
                    label: const Text('更新'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 5,
                      ),
                      textStyle: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
              CatalogEntryStatus.notInstalled => OutlinedButton.icon(
                onPressed: onDownload,
                icon: const Icon(Icons.download, size: 14),
                label: const Text('下载'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 5,
                  ),
                  textStyle: const TextStyle(fontSize: 11.5),
                ),
              ),
              CatalogEntryStatus.upToDate => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check, size: 13, color: AppPalette.ok),
                  Text(
                    '已是最新',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            },
          ],
        ),
      ),
    );
  }

  Widget _badge(String text, Color background, Color foreground) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

/// Screen 17A: empty shelf, one of two guidance paths.
class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf({required this.hasEndpoint, required this.onCheck});

  final bool hasEndpoint;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const SizedBox(height: 20),
        CircleAvatar(
          radius: 36,
          backgroundColor: PaletteScope.of(context).paper2,
          child: Icon(
            Icons.menu_book_outlined,
            size: 32,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Text('还没有文章', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '本地 0 篇 · 应用默认离线，不会自动获取内容；\n在 PC 端发布文章后，手动「检查更新」即可下载。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: hasEndpoint
              ? FilledButton.icon(
                  onPressed: onCheck,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('检查更新'),
                )
              : FilledButton.tonal(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ServiceSetupPage(),
                    ),
                  ),
                  child: const Text('先去配置服务地址'),
                ),
        ),
        const SizedBox(height: 8),
        Text(
          hasEndpoint ? '连接 PC 服务获取目录并选择下载' : '保存地址后回到本屏',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
