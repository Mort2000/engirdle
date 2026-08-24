import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/scope.dart';
import '../../../contracts/readpack_v1/article.dart';
import '../../../shared_kernel/failures.dart';
import '../../importer/application/content_import_service.dart';
import '../domain/raw_source.dart';

/// The import confirmation page (design §6.3): shared by paste and file
/// ingress. Nothing enters the library until 确认导入; going back discards
/// the frozen staging snapshot (§6.2).
class SourceConfirmPage extends StatefulWidget {
  const SourceConfirmPage({required this.preview, super.key});

  final RawSourcePreview preview;

  @override
  State<SourceConfirmPage> createState() => _SourceConfirmPageState();
}

class _SourceConfirmPageState extends State<SourceConfirmPage> {
  late final TextEditingController _title;
  final _author = TextEditingController();
  final _sourceName = TextEditingController();
  final _sourceUrl = TextEditingController();
  String _license = 'unknown';
  bool _warningsAcknowledged = false;
  bool _duplicatesAcknowledged = false;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(
      text: widget.preview.candidate.suggestedTitle,
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    _sourceName.dispose();
    _sourceUrl.dispose();
    super.dispose();
  }

  bool get _hasWarnings => widget.preview.candidate.warnings.isNotEmpty;
  bool get _hasDuplicates =>
      widget.preview.duplicates.exact.isNotEmpty ||
      widget.preview.duplicates.content.isNotEmpty;

  bool get _canConfirm =>
      _title.text.trim().isNotEmpty &&
      (!_hasWarnings || _warningsAcknowledged) &&
      (!_hasDuplicates || _duplicatesAcknowledged) &&
      !_confirming;

  Future<void> _confirm() async {
    if (!_canConfirm) return;
    setState(() => _confirming = true);
    final deps = AppScope.of(context);
    try {
      await deps.contentImport.confirmRawSource(
        widget.preview.importId,
        metadata: ConfirmedSourceMetadata(
          title: _title.text.trim(),
          licenseName: _license,
          author: _author.text.trim().isEmpty ? null : _author.text.trim(),
          sourceDisplayName: _sourceName.text.trim().isEmpty
              ? null
              : _sourceName.text.trim(),
          sourceUrl: _sourceUrl.text.trim().isEmpty
              ? null
              : _sourceUrl.text.trim(),
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${_title.text.trim()}》已保存，可离线阅读。')),
      );
      Navigator.of(context).pop(true);
    } on AppFailure catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：${failureMessage(failure)}')),
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final candidate = widget.preview.candidate;
    final counts = candidate.counts;

    // 返回修改 (§6.2): leaving discards the frozen snapshot — never an
    // empty shell article.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        await AppScope.of(
          context,
        ).contentImport.cancelRawSource(widget.preview.importId);
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('确认导入')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
          children: [
            _sectionLabel(theme, '文章信息'),
            TextField(
              controller: _title,
              decoration: const InputDecoration(
                labelText: '标题（必填）',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _author,
              decoration: const InputDecoration(
                labelText: '作者（可空）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _sourceName,
              decoration: const InputDecoration(
                labelText: '来源名称（可空）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _sourceUrl,
              decoration: const InputDecoration(
                labelText: '来源 URL（可空）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _license,
              decoration: const InputDecoration(
                labelText: '原文许可',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'unknown', child: Text('不确定（unknown）')),
                DropdownMenuItem(
                  value: 'CC0-1.0',
                  child: Text('CC0 1.0（公有领域）'),
                ),
                DropdownMenuItem(value: 'CC-BY-4.0', child: Text('CC BY 4.0')),
                DropdownMenuItem(
                  value: 'CC-BY-SA-4.0',
                  child: Text('CC BY-SA 4.0'),
                ),
                DropdownMenuItem(value: '已获作者授权', child: Text('已获作者授权转载')),
              ],
              onChanged: (value) =>
                  setState(() => _license = value ?? 'unknown'),
            ),
            const SizedBox(height: 14),
            _sectionLabel(theme, '结构预览'),
            Text(
              '约 ${counts.blocks} 个段落块 · ${counts.sentences} 句'
              ' · 表格 ${counts.tables} · 代码块 ${counts.codeBlocks}'
              '${candidate.canTranslate ? '' : ' · 无可翻译单元'}',
              style: theme.textTheme.bodySmall,
            ),
            if (_looksNonEnglish(candidate)) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.translate,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '内容可能不是英文；仍可导入阅读，分词与词典以英文为主。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            ..._previewBlocks(theme, candidate),
            if (_hasWarnings) ...[
              const SizedBox(height: 14),
              _sectionLabel(theme, '结构警告'),
              for (final warning in candidate.warnings)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.warning_amber_rounded,
                    color: theme.colorScheme.error,
                    size: 20,
                  ),
                  title: Text(
                    warning.code == 'unclosed_code_fence'
                        ? '存在未闭合的代码围栏，其后所有内容都会进入代码块；请确认结构无误。'
                        : warning.code,
                    style: theme.textTheme.bodySmall,
                  ),
                  subtitle: warning.blockIndex == null
                      ? null
                      : Text(
                          '位于第 ${warning.blockIndex} 块附近',
                          style: theme.textTheme.bodySmall,
                        ),
                ),
              CheckboxListTile(
                value: _warningsAcknowledged,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('我已确认上述警告符合预期', style: theme.textTheme.bodySmall),
                onChanged: (v) =>
                    setState(() => _warningsAcknowledged = v ?? false),
              ),
            ],
            if (_hasDuplicates) ...[
              const SizedBox(height: 14),
              _sectionLabel(theme, '重复内容'),
              for (final article in widget.preview.duplicates.exact)
                _duplicateRow(theme, '与《${article.title}》原文完全相同（字节级一致）。'),
              for (final article in widget.preview.duplicates.content)
                _duplicateRow(theme, '内容与《${article.title}》一致（仅换行或 BOM 等差异）。'),
              CheckboxListTile(
                value: _duplicatesAcknowledged,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  '我知道本机已有相同内容，仍要再导入一篇',
                  style: theme.textTheme.bodySmall,
                ),
                onChanged: (v) =>
                    setState(() => _duplicatesAcknowledged = v ?? false),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _confirming
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    child: const Text('返回修改'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _canConfirm ? _confirm : null,
                    child: Text(_confirming ? '导入中…' : '确认导入'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// §6.3: warning-only language heuristic — CJK characters dominating the
  /// visible text suggests the source is not English.
  static bool _looksNonEnglish(RawSourceCandidate candidate) {
    var asciiLetters = 0;
    var cjk = 0;
    for (final block in candidate.blocks) {
      if (block is! ParsedTextBlock) continue;
      for (final sentence in block.sentences) {
        for (final rune in sentence.text.runes) {
          if ((rune >= 0x41 && rune <= 0x5A) ||
              (rune >= 0x61 && rune <= 0x7A)) {
            asciiLetters += 1;
          } else if (rune >= 0x4E00 && rune <= 0x9FFF) {
            cjk += 1;
          }
        }
      }
    }
    final total = asciiLetters + cjk;
    return total > 20 && cjk > asciiLetters;
  }

  Widget _duplicateRow(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.copy_outlined,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    ),
  );

  List<Widget> _previewBlocks(ThemeData theme, RawSourceCandidate candidate) {
    final previews = <Widget>[];
    var shown = 0;
    for (final block in candidate.blocks) {
      if (shown >= 3) break;
      if (block is ParsedTextBlock) {
        for (final sentence in block.sentences.take(2)) {
          previews.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                sentence.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          );
        }
        shown += 1;
      } else if (block is ParsedTableBlock) {
        previews.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '[表格 ${block.header.length} 列 · ${block.rows.length} 行]',
              style: theme.textTheme.bodySmall,
            ),
          ),
        );
        shown += 1;
      } else if (block is ParsedCodeBlock) {
        previews.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '[代码块${block.language == null ? '' : ' · ${block.language}'}]',
              style: theme.textTheme.bodySmall,
            ),
          ),
        );
        shown += 1;
      }
    }
    return previews;
  }

  Widget _sectionLabel(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 4),
    child: Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}
