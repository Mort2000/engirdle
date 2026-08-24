import '../../../shared_kernel/failures.dart';

/// Persistent recovery states of one import (design §8.2).
///
/// - `downloading`: package transfer in progress; temp file disposable.
/// - `staged`: extracted + validated under `staging/{import_id}`.
/// - `moving`: files moved to the immutable artifact directory; the DB
///   commit has not necessarily happened — replay or roll back on startup.
/// - `committed`: DB pointer switched; only cleanup remains.
/// - `failed`: import aborted; temp content already removed.
enum ImportState {
  downloading,
  staged,
  moving,
  committed,
  failed;

  /// Null for names written by a newer app version; recovery skips such
  /// rows instead of letting one unknown value fail the whole pass.
  static ImportState? fromName(String name) {
    for (final state in ImportState.values) {
      if (state.name == name) return state;
    }
    return null;
  }
}

/// Recovery-log row for one import operation.
class ImportOperation {
  const ImportOperation({
    required this.importId,
    required this.articleId,
    required this.revision,
    required this.artifactRevision,
    required this.title,
    required this.packageUrl,
    required this.expectedSize,
    required this.expectedSha256,
    required this.state,
    required this.stagingPath,
    this.errorKind,
    this.errorDetail,
  });

  final String importId;
  final String articleId;
  final int revision;
  final int artifactRevision;
  final String title;
  final String packageUrl;
  final int expectedSize;
  final String expectedSha256;
  final ImportState state;
  final String stagingPath;
  final String? errorKind;
  final String? errorDetail;

  ImportOperation copyWith({
    ImportState? state,
    String? errorKind,
    String? errorDetail,
  }) => ImportOperation(
    importId: importId,
    articleId: articleId,
    revision: revision,
    artifactRevision: artifactRevision,
    title: title,
    packageUrl: packageUrl,
    expectedSize: expectedSize,
    expectedSha256: expectedSha256,
    state: state ?? this.state,
    stagingPath: stagingPath,
    errorKind: errorKind,
    errorDetail: errorDetail,
  );
}

/// User-facing phases of the import UI (screen 04B). Labels are deliberately
/// de-engineered; technical detail stays in logs.
enum ImportPhase {
  downloading('下载中'),
  verifyingIntegrity('校验完整性'),
  checkingStructure('检查包结构与大小'),
  extracting('解包内容'),
  validatingContent('校验内容完整性'),
  validatingReferences('校验文章与音频对应'),
  saving('保存到本机'),
  cleaningUp('清理旧版本');

  const ImportPhase(this.label);

  final String label;
}

/// Failure mapped to an import-safe outcome: current install untouched.
class ImportException implements Exception {
  const ImportException(this.failure);

  final AppFailure failure;

  @override
  String toString() => failure.toString();
}
