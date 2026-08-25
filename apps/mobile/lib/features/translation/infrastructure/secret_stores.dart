import 'dart:async';

import '../application/secret_store.dart';

/// In-memory secret store for tests and widget-test dependency graphs.
class InMemorySecretStore implements TranslationSecretStore {
  final Map<String, String> _secrets = {};

  @override
  Future<String?> read(String alias) async => _secrets[alias];

  @override
  Future<void> write(String alias, String secret) async {
    _secrets[alias] = secret;
  }

  @override
  Future<void> delete(String alias) async {
    _secrets.remove(alias);
  }
}
