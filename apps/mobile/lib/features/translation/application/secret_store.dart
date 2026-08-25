/// Credential seam (design §10.1): the translation module reads API keys
/// through this port only. Production uses the Android Keystore-backed
/// adapter; keys never enter SQLite, preferences, job parameters, logs or
/// backups.
abstract interface class TranslationSecretStore {
  /// Returns the secret for [alias], or null when it is not stored.
  Future<String?> read(String alias);

  /// Adds or replaces the secret for [alias].
  Future<void> write(String alias, String secret);

  /// Removes the secret for [alias]; missing aliases are a no-op.
  Future<void> delete(String alias);
}
