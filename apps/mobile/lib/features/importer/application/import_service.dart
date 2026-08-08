import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../contracts/catalog_v1/catalog.dart';
import '../../../contracts/contract_violation.dart';
import '../../../contracts/readpack_v1/readpack_validator.dart';
import '../../../platform/crypto/sha256.dart';
import '../../../platform/filesystem/app_directories.dart';
import '../../../platform/http/lan_http_client.dart';
import '../../../platform/logging/app_logger.dart';
import '../../../platform/zip/secure_zip_reader.dart';
import '../../../shared_kernel/content_identity.dart';
import '../../../shared_kernel/failures.dart';
import '../../../shared_kernel/id_generator.dart';
import '../../library/application/library_service.dart';
import '../domain/import_models.dart';
import '../infrastructure/import_log_dao.dart';

/// The import pipeline (MOB-DL-001, MOB-IMP-001/002/003, design §8.2):
///
/// download to temp → outer size+SHA-256 → ZIP preflight → stream extract to
/// staging → schema/reference/hash validation → move to the immutable
/// artifact directory → single DB transaction switches the pointer → async
/// cleanup. Every failure leaves the previous revision untouched.
class ImportService {
  ImportService({
    required ImportLogDao logDao,
    required LibraryService library,
    required LanHttpClient httpClient,
    required AppDirectories directories,
    this.zipReader = const SecureZipReader(),
    this.validator = const ReadpackValidator(),
    AppLogger? logger,
  })  : _logDao = logDao,
        _library = library,
        _http = httpClient,
        _dirs = directories,
        _logger = logger ?? const AppLogger('importer');

  final ImportLogDao _logDao;
  final LibraryService _library;
  final LanHttpClient _http;
  final AppDirectories _dirs;
  final SecureZipReader zipReader;
  final ReadpackValidator validator;
  final AppLogger _logger;

  /// v1 logical layout allow-list (design §6.1).
  static const allowedPaths = {
    'manifest.json',
    'article.json',
    'attribution.json',
    'audio/article.m4a',
  };

  /// Imports [package] end to end. Returns the installed article reference.
  ///
  /// [onPhase] reports user-facing phases; [onDownloadProgress] reports
  /// bytes. Throws [AppFailure]; the current install is never damaged.
  Future<ArticleRef> importPackage(
    CatalogPackage package, {
    void Function(ImportPhase phase)? onPhase,
    void Function(int receivedBytes, int? totalBytes)? onDownloadProgress,
    CancelToken? cancelToken,
  }) async {
    final importId = newUuid();
    final ref = ArticleRef(
      articleId: package.articleId,
      revision: package.revision,
      artifactRevision: package.artifactRevision,
    );
    final downloadFile = _dirs.downloadFile(importId);
    final stagingDir = _dirs.stagingDir(importId);
    final op = ImportOperation(
      importId: importId,
      articleId: package.articleId,
      revision: package.revision,
      artifactRevision: package.artifactRevision,
      title: package.title,
      packageUrl: package.url.toString(),
      expectedSize: package.size,
      expectedSha256: package.sha256,
      state: ImportState.downloading,
      stagingPath: stagingDir.path,
    );
    _logDao.insert(op);
    _logger.info('import.start', {'article': ref.toString()});

    var movedToFinal = false;
    // Set once commitInstall returns: the DB pointer has switched, so the
    // artifact directory is live and abort/recovery must never delete it.
    var committed = false;
    Directory? finalDir;
    try {
      // 1. Download to a disposable file (MOB-DL-001).
      onPhase?.call(ImportPhase.downloading);
      await _http.downloadToFile(
        package.url,
        downloadFile,
        onProgress: onDownloadProgress,
        cancelToken: cancelToken,
      );
      _throwIfCancelled(cancelToken);

      // 2. Outer size + SHA-256 against the catalog declaration.
      onPhase?.call(ImportPhase.verifyingIntegrity);
      final actualSize = await downloadFile.length();
      if (actualSize != package.size) {
        throw const AppFailure(FailureKind.download, 'size mismatch');
      }
      final actualHash = await sha256OfFile(downloadFile);
      if (actualHash != package.sha256) {
        throw const AppFailure(FailureKind.download, 'sha256 mismatch');
      }

      // 3. ZIP preflight: central directory + limits, before any write.
      onPhase?.call(ImportPhase.checkingStructure);
      final entries = await zipReader.preflight(downloadFile);
      final paths = entries.map((e) => e.path).toSet();
      if (paths.length != allowedPaths.length ||
          !paths.containsAll(allowedPaths)) {
        throw const AppFailure(
            FailureKind.packageFormat, 'unexpected package layout');
      }

      // 4. Stream extraction into staging with real byte accounting.
      onPhase?.call(ImportPhase.extracting);
      for (final entry in entries) {
        _throwIfCancelled(cancelToken);
        await zipReader.extractEntry(
            downloadFile, entry, File(p.join(stagingDir.path, entry.path)));
      }
      _logDao.updateState(importId, ImportState.staged);

      // 5. Manifest / references / hashes validation.
      onPhase?.call(ImportPhase.validatingContent);
      final stagedFiles = {
        for (final path in allowedPaths) path: File(p.join(stagingDir.path, path)),
      };
      final validated = await validator.validate(stagedFiles,
          sha256Of: sha256OfFile);
      onPhase?.call(ImportPhase.validatingReferences);
      _requireMatchesCatalog(validated, package);

      // 6. Move to the immutable artifact directory, then commit the DB
      //    pointer switch in one short transaction (MOB-IMP-002).
      onPhase?.call(ImportPhase.saving);
      finalDir = _library.artifactDirectory(ref);
      if (await finalDir.exists()) {
        throw const AppFailure(
            FailureKind.packageFormat, 'artifact already exists');
      }
      _logDao.updateState(importId, ImportState.moving);
      await finalDir.parent.create(recursive: true);
      await stagingDir.rename(finalDir.path);
      movedToFinal = true;
      final manifestJson =
          await File(p.join(finalDir.path, 'manifest.json')).readAsString();
      final attributionJson =
          await File(p.join(finalDir.path, 'attribution.json')).readAsString();
      _library.commitInstall(
        content: validated.article,
        manifest: validated.manifest,
        manifestJson: manifestJson,
        attributionJson: attributionJson,
      );
      committed = true;
      _logDao.updateState(importId, ImportState.committed);

      // 7. Async cleanup: temp download, old artifacts (MOB-IMP-003).
      //    Cleanup runs after the commit, so its failure must not abort the
      //    import (abort would delete the artifact the DB now points at).
      //    The log row is kept so startup recovery retries the cleanup.
      onPhase?.call(ImportPhase.cleaningUp);
      try {
        await _cleanupTemp(downloadFile, stagingDir);
        await _library.cleanupOldArtifacts(ref);
        _logDao.delete(importId);
      } catch (e) {
        _logger.warn('import.cleanup_failed', {'error': '$e'});
      }
      _logger.info('import.committed', {'article': ref.toString()});
      return ref;
    } on AppFailure catch (failure) {
      await _abort(op, downloadFile, stagingDir, finalDir, movedToFinal,
          committed, failure);
      rethrow;
    } on ContractViolation catch (e) {
      // Contract violations are package-format failures by definition
      // (see ContractViolation's class contract), never database ones.
      final failure = AppFailure(
          FailureKind.packageFormat, 'package contract violation',
          detail: '$e');
      await _abort(op, downloadFile, stagingDir, finalDir, movedToFinal,
          committed, failure);
      throw failure;
    } catch (e) {
      final failure =
          AppFailure(FailureKind.database, 'import failed', detail: '$e');
      await _abort(op, downloadFile, stagingDir, finalDir, movedToFinal,
          committed, failure);
      throw failure;
    }
  }

  /// Startup recovery for imports interrupted at any point (design §8.2).
  ///
  /// - downloading/staged: temp content is dropped; old install untouched.
  /// - moving: the artifact directory is re-validated; valid → replay the DB
  ///   commit, invalid → roll back by deleting it.
  /// - committed: cleanup is re-run.
  Future<void> recoverUnfinished() async {
    for (final op in _logDao.unfinished()) {
      // A single broken record must not block recovery of the others.
      try {
        await _recoverOne(op);
      } catch (e) {
        _logger.error('import.recover.failed',
            {'import_id': op.importId, 'error': '$e'});
      }
    }
  }

  Future<void> _recoverOne(ImportOperation op) async {
    _logger.warn(
        'import.recover', {'import_id': op.importId, 'state': op.state.name});
    final downloadFile = _dirs.downloadFile(op.importId);
    // Rebuild the staging path from the validated import id instead of
    // trusting the DB-stored path.
    final stagingDir = _dirs.stagingDir(op.importId);
    final ref = ArticleRef(
      articleId: op.articleId,
      revision: op.revision,
      artifactRevision: op.artifactRevision,
    );
    switch (op.state) {
      case ImportState.downloading:
      case ImportState.staged:
        await _cleanupTemp(downloadFile, stagingDir);
        _logDao.delete(op.importId);
      case ImportState.moving:
        await _recoverMoving(op, ref, downloadFile, stagingDir);
      case ImportState.committed:
        await _cleanupTemp(downloadFile, stagingDir);
        // The logged ref may be stale: if a newer revision was installed
        // after this row's cleanup failed, deleting "old" artifacts would
        // delete the current install. Only clean when the DB still points
        // at the ref this row committed.
        final current = _library.getArticle(op.articleId);
        if (current != null && current.ref == ref) {
          await _library.cleanupOldArtifacts(ref);
        }
        _logDao.delete(op.importId);
      case ImportState.failed:
        await _cleanupTemp(downloadFile, stagingDir);
        _logDao.delete(op.importId);
    }
  }

  Future<void> _recoverMoving(
    ImportOperation op,
    ArticleRef ref,
    File downloadFile,
    Directory stagingDir,
  ) async {
    final finalDir = _library.artifactDirectory(ref);
    if (await finalDir.exists()) {
      // Re-validate the moved artifact, then replay the DB commit. Only a
      // validation/DB failure rolls back (deletes the artifact).
      try {
        final files = {
          for (final path in allowedPaths)
            path: File(p.join(finalDir.path, path)),
        };
        final validated =
            await validator.validate(files, sha256Of: sha256OfFile);
        final manifestJson =
            await File(p.join(finalDir.path, 'manifest.json')).readAsString();
        final attributionJson =
            await File(p.join(finalDir.path, 'attribution.json'))
                .readAsString();
        _library.commitInstall(
          content: validated.article,
          manifest: validated.manifest,
          manifestJson: manifestJson,
          attributionJson: attributionJson,
        );
        _logDao.updateState(op.importId, ImportState.committed);
      } catch (e) {
        // The original commit may have landed while only its bookkeeping
        // failed (commitInstall succeeded, the state update did not). If the
        // DB already points at this ref, the artifact is live: never delete
        // it — continue as committed instead.
        final current = _library.getArticle(op.articleId);
        if (current == null || current.ref != ref) {
          _logger.error('import.recover.rollback', {'error': '$e'});
          await finalDir.delete(recursive: true);
          await _cleanupTemp(downloadFile, stagingDir);
          _logDao.delete(op.importId);
          return;
        }
        _logger.warn('import.recover.commit_landed', {'error': '$e'});
      }
      // Committed: cleanup is best-effort; failure keeps the log row so the
      // next startup retries via the committed branch.
      try {
        await _cleanupTemp(downloadFile, stagingDir);
        await _library.cleanupOldArtifacts(ref);
        _logDao.delete(op.importId);
      } catch (e) {
        _logger.warn('import.cleanup_failed', {'error': '$e'});
      }
      return;
    }
    await _cleanupTemp(downloadFile, stagingDir);
    _logDao.delete(op.importId);
  }

  Future<void> _abort(
    ImportOperation op,
    File downloadFile,
    Directory stagingDir,
    Directory? finalDir,
    bool movedToFinal,
    bool committed,
    AppFailure failure,
  ) async {
    _logger.warn('import.failed', {
      'import_id': op.importId,
      'kind': failure.kind.name,
      'reason': failure.message,
    });
    // Every rollback step is best-effort: a secondary cleanup failure must
    // be logged, never mask the original failure the caller rethrows.
    // Once the DB commit landed, the artifact directory is live — deleting
    // it would break the install the DB now points at.
    if (!committed && movedToFinal && finalDir != null) {
      try {
        if (await finalDir.exists()) await finalDir.delete(recursive: true);
      } catch (e) {
        _logger.error('import.abort.artifact_delete_failed', {'error': '$e'});
      }
    }
    try {
      await _cleanupTemp(downloadFile, stagingDir);
    } catch (e) {
      _logger.error('import.abort.temp_cleanup_failed', {'error': '$e'});
    }
    try {
      _logDao.updateState(op.importId, ImportState.failed,
          errorKind: failure.kind.name, errorDetail: failure.message);
    } catch (e) {
      _logger.error('import.abort.log_update_failed', {'error': '$e'});
    }
    try {
      _logDao.delete(op.importId);
    } catch (e) {
      _logger.error('import.abort.log_delete_failed', {'error': '$e'});
    }
  }

  Future<void> _cleanupTemp(File downloadFile, Directory stagingDir) async {
    if (await downloadFile.exists()) await downloadFile.delete();
    if (await stagingDir.exists()) await stagingDir.delete(recursive: true);
  }

  static void _throwIfCancelled(CancelToken? token) {
    if (token?.isCancelled ?? false) {
      throw const AppFailure(FailureKind.download, 'cancelled');
    }
  }

  /// The package content must be exactly what the catalog announced.
  static void _requireMatchesCatalog(
      ValidatedReadpack validated, CatalogPackage package) {
    final manifest = validated.manifest;
    if (manifest.articleId != package.articleId ||
        manifest.revision != package.revision ||
        manifest.artifactRevision != package.artifactRevision) {
      throw const AppFailure(
          FailureKind.packageFormat, 'package identity mismatch with catalog');
    }
  }
}
