/// Typed translation failures (mobile design §8.5; mirrors the PC module's
/// deepseek_errors taxonomy so both implementations classify the same way).
///
/// The wire protocol errors live here because both the response validator and
/// the DeepSeek adapter raise them; job-level error kinds in
/// translation_models.dart are derived from these.
class TranslationProtocolError implements Exception {
  const TranslationProtocolError(this.message);

  final String message;

  @override
  String toString() => 'TranslationProtocolError: $message';
}

class TranslationConfigError implements Exception {
  const TranslationConfigError(this.message);

  final String message;

  @override
  String toString() => 'TranslationConfigError: $message';
}
