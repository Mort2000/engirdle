import '../domain/translation_errors.dart';
import '../domain/translation_models.dart';
import '../infrastructure/deepseek_adapter.dart';
import '../infrastructure/translation_dao.dart';
import 'llm_client.dart';
import 'secret_store.dart';

/// Settings-page use cases (design §12.4): profile + API key management and
/// the explicit connection test. The key only travels between the page, the
/// secret store and the adapter — it is never persisted in the profile row,
/// logs or job parameters.
class TranslationSettingsService {
  TranslationSettingsService({
    required TranslationDao dao,
    required TranslationSecretStore secrets,
    required LlmCompletionClient client,
  }) : _dao = dao,
       _secrets = secrets,
       _client = client;

  final TranslationDao _dao;
  final TranslationSecretStore _secrets;
  final LlmCompletionClient _client;

  LlmProfile? profile() => _dao.readProfile();

  /// Whether a key is stored (presence only — never the material).
  Future<bool> hasKey() async {
    final secret = await _secrets.read(kDeepSeekSecretAlias);
    return secret != null && secret.trim().isNotEmpty;
  }

  /// First-time configuration: stores the key and creates the profile.
  Future<void> configure({
    required String apiKey,
    String model = kDeepSeekDefaultModel,
  }) async {
    final key = _requireKey(apiKey);
    await _secrets.write(kDeepSeekSecretAlias, key);
    _saveProfile(model: model);
  }

  /// Replaces an existing key (origin stays bound to the fixed endpoint).
  Future<void> replaceKey(String apiKey) async {
    final key = _requireKey(apiKey);
    await _secrets.write(kDeepSeekSecretAlias, key);
  }

  Future<void> deleteKey() => _secrets.delete(kDeepSeekSecretAlias);

  void updateModel(String model) {
    final trimmed = model.trim();
    if (trimmed.isEmpty) {
      throw const TranslationConfigError('model must not be empty');
    }
    _saveProfile(model: trimmed);
  }

  void updateConstraints({bool? wifiOnly, bool? chargingOnly}) {
    final profile = _dao.readProfile();
    if (profile == null) return;
    _dao.saveProfile(
      profile.copyWith(wifiOnly: wifiOnly, chargingOnly: chargingOnly),
    );
  }

  /// Explicit, user-triggered availability test (§10.2): verifies the key
  /// works AND the configured model is served by the provider.
  Future<ConnectionTestResult> testConnection() async {
    final profile = _dao.readProfile();
    if (profile == null) return ConnectionTestResult.notConfigured;
    if (!await hasKey()) return ConnectionTestResult.notConfigured;
    try {
      final models = await _client.listModels(
        timeout: const Duration(seconds: 15),
      );
      if (!models.contains(profile.model)) {
        return ConnectionTestResult.modelUnavailable;
      }
      return ConnectionTestResult.ok;
    } on LlmException catch (error) {
      return switch (error.kind) {
        LlmErrorKind.auth => ConnectionTestResult.auth,
        LlmErrorKind.balance => ConnectionTestResult.balance,
        LlmErrorKind.config => ConnectionTestResult.notConfigured,
        _ => ConnectionTestResult.network,
      };
    }
  }

  String _requireKey(String apiKey) {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw const TranslationConfigError('API key must not be empty');
    }
    return key;
  }

  void _saveProfile({required String model}) {
    _dao.saveProfile(
      LlmProfile(
        provider: kDeepSeekProvider,
        origin: kDeepSeekOfficialOrigin,
        model: model,
        secretAlias: kDeepSeekSecretAlias,
        wifiOnly: _dao.readProfile()?.wifiOnly ?? false,
        chargingOnly: _dao.readProfile()?.chargingOnly ?? false,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }
}

enum ConnectionTestResult { ok, modelUnavailable, auth, balance, network, notConfigured }
