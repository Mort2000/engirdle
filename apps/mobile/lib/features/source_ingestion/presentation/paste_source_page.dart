import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/scope.dart';
import '../../../shared_kernel/failures.dart';
import 'source_confirm_page.dart';
import '../domain/raw_source.dart';

/// The paste entry (design §6.2): a real source adapter, not a scratchpad.
/// Content exists only in the editor state until 预览 freezes it into
/// staging; the clipboard is never read automatically.
class PasteSourcePage extends StatefulWidget {
  const PasteSourcePage({super.key});

  @override
  State<PasteSourcePage> createState() => _PasteSourcePageState();
}

class _PasteSourcePageState extends State<PasteSourcePage> {
  final _controller = TextEditingController();
  SourceSyntax _syntax = SourceSyntax.plainText;
  bool _previewing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _byteCount => utf8.encode(_controller.text).length;

  bool get _overLimit =>
      _byteCount > 8 * 1024 * 1024 || _controller.text.isEmpty;

  Future<void> _preview() async {
    if (_previewing || _overLimit) return;
    setState(() => _previewing = true);
    final deps = AppScope.of(context);
    try {
      final preview = await deps.contentImport.stageRawSource(
        rawBytes: utf8.encode(_controller.text),
        syntax: _syntax,
        origin: 'paste',
      );
      if (!mounted) return;
      // 返回修改 discards the frozen snapshot (§6.2); the editor text is
      // kept verbatim below the confirmation page.
      final installed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => SourceConfirmPage(preview: preview)),
      );
      if (installed == true && mounted) {
        Navigator.of(context).pop(true);
      }
    } on AppFailure catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_stageFailureText(failure))));
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  static String _stageFailureText(AppFailure failure) {
    final detail = failure.detail ?? '';
    if (detail.contains('raw_html')) return '内容包含 HTML 片段，移动端不支持；请删除 HTML 后重试。';
    if (detail.contains('link_reference_definition')) {
      return '内容包含链接引用定义（[标签]: 地址），移动端不支持；请改用完整链接。';
    }
    if (detail.contains('autolink'))
      return '内容包含 <自动链接>，移动端不支持；请使用 [文字](地址) 形式。';
    if (detail.contains('html_entity'))
      return '内容包含 HTML 实体（如 &amp;），移动端不支持；请改用字符本身。';
    if (detail.contains('empty_body')) return '内容为空或全是空白，无法导入。';
    if (detail.contains('source_too_large')) return '内容超过 8 MiB 上限；请拆分后再导入。';
    if (detail.contains('resource_limit'))
      return '内容超出资源上限（块/句/表格/代码），请精简后再导入。';
    if (detail.contains('nesting_depth')) return '引用或列表嵌套超过 4 层，请减少嵌套。';
    return '解析失败：${failureMessage(failure)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overLimit = _byteCount > 8 * 1024 * 1024;
    return Scaffold(
      appBar: AppBar(title: const Text('粘贴原文')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<SourceSyntax>(
              segments: const [
                ButtonSegment(
                  value: SourceSyntax.plainText,
                  label: Text('纯文本'),
                ),
                ButtonSegment(
                  value: SourceSyntax.markdown,
                  label: Text('Markdown'),
                ),
              ],
              selected: {_syntax},
              onSelectionChanged: (selection) =>
                  setState(() => _syntax = selection.first),
            ),
            const SizedBox(height: 4),
            Text(
              _syntax == SourceSyntax.plainText
                  ? '纯文本按空行分段、按句切分，不解释任何标记。'
                  : 'Markdown 支持常用子集；不支持的语法会在预览时明确提示。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                autofocus: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '粘贴或输入英文原文…',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    overLimit
                        ? '当前 $_byteCount 字节，超过 8 MiB 上限，无法预览。'
                        : '$_byteCount 字节（UTF-8）· 上限 8 MiB',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: overLimit ? theme.colorScheme.error : null,
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: (_previewing || _overLimit) ? null : _preview,
                  child: Text(_previewing ? '解析中…' : '预览'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
