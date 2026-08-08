/// Typed failure taxonomy for the Android client (design §10).
///
/// Presentation maps each category to an actionable, de-engineered message;
/// technical details stay in logs and the attribution page.
library;

enum FailureKind {
  connection,
  download,
  packageFormat,
  resourceLimit,
  database,
  player,
}

/// Expected, user-presentable failure. Never carries secrets or raw payloads.
class AppFailure implements Exception {
  const AppFailure(this.kind, this.message, {this.detail});

  final FailureKind kind;

  /// Short technical reason (e.g. `connection refused`, `sha256 mismatch`).
  final String message;

  /// Optional structured context for logs; never shown verbatim in UI.
  final String? detail;

  @override
  String toString() =>
      'AppFailure(${kind.name}: $message${detail == null ? '' : ' | $detail'})';
}
