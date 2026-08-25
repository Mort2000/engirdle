import 'package:flutter/services.dart';

import '../application/secret_store.dart';

/// Production secret store backed by the Android Keystore (design §10.1):
/// the key material is encrypted with a non-exportable AES-GCM key held by
/// AndroidKeyStore and stored under the no-backup files dir, so it never
/// reaches SQLite, preferences, job parameters, logs or cloud backups. The
/// encryption key requires no biometric unlock — background translation must
/// run unattended; a stronger per-use-authenticating key would make that
/// impossible (§10.1).
class KeystoreSecretStore implements TranslationSecretStore {
  const KeystoreSecretStore();

  static const _channel = MethodChannel('com.engirdle.mobile/secrets');

  @override
  Future<String?> read(String alias) async {
    final secret = await _channel.invokeMethod<String>('read', {
      'alias': alias,
    });
    return (secret == null || secret.isEmpty) ? null : secret;
  }

  @override
  Future<void> write(String alias, String secret) =>
      _channel.invokeMethod<void>('write', {
        'alias': alias,
        'secret': secret,
      });

  @override
  Future<void> delete(String alias) =>
      _channel.invokeMethod<void>('delete', {'alias': alias});
}
