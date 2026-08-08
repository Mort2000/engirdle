import 'package:flutter/material.dart';

import '../../../app/format.dart';
import '../../../app/scope.dart';
import '../../../app/theme.dart';
import '../../../shared_kernel/failures.dart';
import '../domain/service_endpoint.dart';

/// Screen 01/02: configure, verify and save the LAN publisher URL — the
/// app's only network entry point (MOB-NET-001).
class ServiceSetupPage extends StatefulWidget {
  const ServiceSetupPage({super.key, this.isFirstRun = false});

  final bool isFirstRun;

  @override
  State<ServiceSetupPage> createState() => _ServiceSetupPageState();
}

class _ServiceSetupPageState extends State<ServiceSetupPage> {
  final _controller = TextEditingController();
  ServiceEndpoint? _endpoint;
  String? _inlineError;
  bool _busy = false;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // AppScope is an InheritedWidget; reading it in initState throws, so the
    // initial endpoint load waits for dependencies (guarded against re-entry).
    if (_loaded) return;
    _loaded = true;
    _endpoint = AppScope.of(context).connection.current();
    _controller.text = _endpoint?.baseUrl.toString() ?? '';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _inlineError = null;
    });
    final connection = AppScope.of(context).connection;
    try {
      final endpoint = connection.saveUrl(_controller.text);
      final catalog = await connection.verify();
      if (!mounted) return;
      setState(() => _endpoint = endpoint);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF234534),
        content: Text('验证成功：目录服务可用，已发现 ${catalog.packages.length} 篇可下载文章，可保存。'),
      ));
    } on AppFailure catch (failure) {
      if (!mounted) return;
      _handleFailure(failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    final connection = AppScope.of(context).connection;
    try {
      final endpoint = connection.saveUrl(_controller.text);
      setState(() {
        _endpoint = endpoint;
        _inlineError = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已保存。尚未验证的地址在检查更新前需要先验证。'),
      ));
      if (widget.isFirstRun) {
        Navigator.of(context).pop();
      }
    } on AppFailure catch (failure) {
      _handleFailure(failure);
    }
  }

  void _handleFailure(AppFailure failure) {
    // Format-class errors stay inline (02B); transport errors use the
    // categorized dialog (02A).
    final inline = failure.kind == FailureKind.connection &&
        (failure.message == 'invalid url' ||
            failure.message == 'non-lan http rejected');
    if (inline) {
      setState(() => _inlineError = failureMessage(failure));
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.error_outline, color: AppPalette.error),
        title: const Text('无法连接服务'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(failureMessage(failure)),
            const SizedBox(height: 10),
            Text(
              '错误分类：${failureKindLabel(failure.kind)} · 本机内容与已安装文章不受影响。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _verify();
            },
            child: const Text('重试验证'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verified = _endpoint?.isVerified ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('连接内容服务'),
            if (widget.isFirstRun)
              Text('首次启动 · 第 1 步，共 1 步',
                  style: theme.textTheme.labelSmall),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (widget.isFirstRun)
            Card(
              color: AppPalette.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('欢迎使用 Engirdle',
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    const Text(
                      '在 PC 端发布文章后，输入 PC 的局域网只读服务地址，即可手动检查目录并下载文章。应用默认离线、不会自动连接该地址；下载完成后全部功能离线可用。',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 4),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: '服务基础 URL（HTTP / HTTPS）',
              hintText: 'http://192.168.1.12:8766',
              errorText: _inlineError,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_inlineError != null) setState(() => _inlineError = null);
            },
          ),
          const SizedBox(height: 6),
          Text(
            _endpoint == null
                ? 'PC 端管理界面 →「局域网发布」中显示的地址与端口。服务默认关闭，需在 PC 端显式开启。'
                : '上次验证：${verified ? '成功' : '失败'} · ${_endpoint!.verifiedAt == null ? '从未' : formatRelative(_endpoint!.verifiedAt!)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : _verify,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(_busy ? '验证中…' : '验证连接'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const _WarningBanner(),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.shield_outlined,
                        size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Text('Android 权限与明文流量说明',
                        style: theme.textTheme.labelLarge),
                  ]),
                  const SizedBox(height: 5),
                  Text(
                    // The manifest allows cleartext globally; the rejection of
                    // non-LAN plaintext happens in-app — copy must say so.
                    '· 需要「局域网访问」权限（安装时授予）；\n'
                    '· 明文 HTTP 仅允许局域网地址；公网明文请求在应用内一律拒绝；\n'
                    '· HTTPS 地址正常支持。',
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
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.amberContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, size: 18, color: AppPalette.amber),
          SizedBox(width: 9),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: '仅在受信任的局域网使用。',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                TextSpan(text: '该服务为无鉴权只读服务，请勿填写公网地址；完整性校验只能发现传输损坏，不能证明来源身份。'),
              ]),
              style: TextStyle(fontSize: 12, color: Color(0xFF5C3F00)),
            ),
          ),
        ],
      ),
    );
  }
}
