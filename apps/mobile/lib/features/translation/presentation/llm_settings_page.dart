import 'package:flutter/material.dart';

import '../../../app/scope.dart';
import '../../../app/theme.dart';
import '../application/translation_settings_service.dart';
import '../domain/translation_errors.dart';
import '../infrastructure/deepseek_adapter.dart';

/// 翻译服务设置（design §12.4）：provider 与官方端点固定展示，密钥只在此
/// 页输入并送入 Keystore，从不回显完整内容；连接测试由用户显式触发。
class LlmSettingsPage extends StatefulWidget {
  const LlmSettingsPage({super.key});

  @override
  State<LlmSettingsPage> createState() => _LlmSettingsPageState();
}

class _LlmSettingsPageState extends State<LlmSettingsPage> {
  final _keyController = TextEditingController();
  final _modelController = TextEditingController();
  bool _keyStored = false;
  bool _testing = false;
  ConnectionTestResult? _testResult;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final profile = _settings().profile();
    _modelController.text = profile?.model ?? kDeepSeekDefaultModel;
    _settings().hasKey().then((stored) {
      if (mounted) setState(() => _keyStored = stored);
    });
  }

  var _initialized = false;

  @override
  void dispose() {
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  TranslationSettingsService _settings() =>
      AppScope.of(context).translationSettings;

  Future<void> _saveKey() async {
    try {
      if (_keyStored) {
        await _settings().replaceKey(_keyController.text);
      } else {
        await _settings().configure(
          apiKey: _keyController.text,
          model: _modelController.text.trim().isEmpty
              ? kDeepSeekDefaultModel
              : _modelController.text.trim(),
        );
      }
      if (!mounted) return;
      setState(() {
        _keyStored = true;
        _keyController.clear();
        _testResult = null;
      });
      _snack('密钥已保存到本机安全存储。');
    } on TranslationConfigError {
      _snack('密钥不能为空。');
    }
  }

  Future<void> _deleteKey() async {
    await _settings().deleteKey();
    if (!mounted) return;
    setState(() {
      _keyStored = false;
      _testResult = null;
    });
    _snack('密钥已删除；已排队的任务会因缺少密钥而停止。');
  }

  Future<void> _testConnection() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final result = await _settings().testConnection();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String get _testResultText => switch (_testResult) {
    ConnectionTestResult.ok => '连接成功，所选模型可用。',
    ConnectionTestResult.modelUnavailable => '连接成功，但该模型不在服务列表中，请检查模型名。',
    ConnectionTestResult.auth => '密钥被拒绝，请重新填写。',
    ConnectionTestResult.balance => '账户余额不足。',
    ConnectionTestResult.network => '网络或服务暂不可用，请稍后再试。',
    ConnectionTestResult.notConfigured => '尚未保存密钥，无法测试。',
    null => '',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('翻译服务')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('服务商', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text('DeepSeek（官方端点 $kDeepSeekOfficialOrigin，固定不可更改）',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text(
                    '翻译需自备 DeepSeek API Key。密钥保存在本机安全存储（Android '
                    'Keystore 加密），不进入应用数据库、日志或备份；全文仅在你显'
                    '式开始翻译时发送到该官方端点。',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('模型', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _modelController,
                    enabled: _keyStored,
                    decoration: const InputDecoration(
                      hintText: 'deepseek-chat',
                      isDense: true,
                    ),
                    onSubmitted: (value) {
                      try {
                        _settings().updateModel(
                          value.trim().isEmpty
                              ? kDeepSeekDefaultModel
                              : value.trim(),
                        );
                        _modelController.text = value.trim().isEmpty
                            ? kDeepSeekDefaultModel
                            : value.trim();
                        _snack('模型已更新，后续任务将使用新模型。');
                      } on TranslationConfigError {
                        _snack('模型名不能为空。');
                      }
                    },
                  ),
                  if (!_keyStored)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('保存密钥后可修改模型。', style: TextStyle(fontSize: 11)),
                    ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('API Key', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    _keyStored ? '已保存（出于安全考虑不回显内容）' : '未保存',
                    style: TextStyle(
                      fontSize: 12,
                      color: _keyStored ? AppPalette.ok : theme.hintColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('api-key-field'),
                    controller: _keyController,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      hintText: _keyStored ? '输入新密钥以替换' : '粘贴 DeepSeek API Key',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: _saveKey,
                        child: Text(_keyStored ? '替换密钥' : '保存密钥'),
                      ),
                      const SizedBox(width: 8),
                      if (_keyStored)
                        OutlinedButton(
                          onPressed: _deleteKey,
                          child: const Text('删除密钥'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('连接测试', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    '验证密钥有效且所选模型可用；只在点击时连接。此测试只访问模型列'
                    '表，不发送文章内容。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: _keyStored && !_testing ? _testConnection : null,
                    child: Text(_testing ? '测试中…' : '测试连接'),
                  ),
                  if (_testResult != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _testResultText,
                      style: TextStyle(
                        fontSize: 12,
                        color: _testResult == ConnectionTestResult.ok
                            ? AppPalette.ok
                            : theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('网络与电源', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    '限制翻译任务运行的条件，随后台执行能力开放后生效。',
                    style: theme.textTheme.bodySmall,
                  ),
                  _ConstraintsCard(settings: _settings()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConstraintsCard extends StatefulWidget {
  const _ConstraintsCard({required this.settings});

  final TranslationSettingsService settings;

  @override
  State<_ConstraintsCard> createState() => _ConstraintsCardState();
}

class _ConstraintsCardState extends State<_ConstraintsCard> {
  @override
  Widget build(BuildContext context) {
    final profile = widget.settings.profile();
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('仅 Wi-Fi 时翻译'),
          value: profile?.wifiOnly ?? false,
          onChanged: (enabled) {
            widget.settings.updateConstraints(wifiOnly: enabled);
            setState(() {});
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('仅充电时翻译'),
          value: profile?.chargingOnly ?? false,
          onChanged: (enabled) {
            widget.settings.updateConstraints(chargingOnly: enabled);
            setState(() {});
          },
        ),
      ],
    );
  }
}
