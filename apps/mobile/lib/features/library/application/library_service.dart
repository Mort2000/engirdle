import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../platform/filesystem/app_directories.dart';
import '../../../shared_kernel/content_identity.dart';
import '../../../shared_kernel/failures.dart';
import '../../playback/domain/lease_registry.dart';
import '../domain/article_install.dart';
import '../domain/installed_article.dart';
import '../infrastructure/library_dao.dart';

/// Library use cases: installed-article index, content queries, atomic
/// install commit and safe deletion (MOB-LIB-001, MOB-IMP-002/003).
class LibraryService {
  LibraryService({
    required LibraryDao dao,
    required AppDirectories directories,
    LeaseRegistry? playbackLeases,
    InstallPackagedTranslation? packagedTranslationInstaller,
  }) : _dao = dao,
       _dirs = directories,
       _leases = playbackLeases,
       _installPackagedTranslation = packagedTranslationInstaller;

  final LibraryDao _dao;
  final AppDirectories _dirs;
  final InstallPackagedTranslation? _installPackagedTranslation;

  /// Last-resort guard so an upgrade cleanup or a delete cannot remove an
  /// artifact a background playback session still holds (design §6.3). Null in
  /// tests that don't care about playback.
  final LeaseRegistry? _leases;

  final StreamController<void> _changes = StreamController.broadcast();

  /// Notifies whenever installed content or capabilities changed (install,
  /// delete, active-translation switch). The reader refreshes its projection
  /// from this instead of polling (lightweight-readpack design §12.3).
  Stream<void> get changes => _changes.stream;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Re-emits a change event for work committed by another engine: with
  /// background translation (§9.2) the worker engine activates sets on its
  /// own connection, and this engine's in-process notify never fires. The
  /// cross-engine observer in the translation module calls this; nothing is
  /// re-read or validated here.
  void notifyExternalChange() => _notify();

  /// Releases the change stream (composition-root disposal).
  void dispose() => _changes.close();

  List<InstalledArticle> listArticles() => _dao.listArticles();

  InstalledArticle? getArticle(String articleId) => _dao.getArticle(articleId);

  /// Full content for the reader; null when the article is not installed.
  /// Derivatives compose by capability: audio exists only with a narration
  /// asset, translations only with an active complete set.
  InstalledContent? getContent(String articleId) {
    final article = _dao.getArticle(articleId);
    if (article == null) return null;
    final narration = article.narration;
    return InstalledContent(
      article: article,
      blocks: _dao.getBlocks(articleId),
      capabilities: ArticleCapabilities(
        hasTranslation: _dao.hasActiveTranslation(articleId),
        hasNarration: narration != null,
      ),
      audioFilePath: narration == null
          ? null
          : File(
              p.join(
                _dirs
                    .articleDir(
                      articleId,
                      article.revision,
                      article.artifactRevision,
                    )
                    .path,
                narration.audioPath,
              ),
            ).path,
    );
  }

  /// Atomically switches the article's active translation set. The set must
  /// be complete and cover the current base exactly (validated in the DAO
  /// transaction); rejections leave the previous activation untouched.
  void activateTranslation(String articleId, String translationSetId) {
    try {
      _dao.activateTranslation(articleId, translationSetId);
      _notify();
    } catch (e) {
      throw AppFailure(
        FailureKind.database,
        'translation activation failed',
        detail: e.toString(),
      );
    }
  }

  /// Raw manifest/attribution JSON for the attribution page.
  ({String manifestJson, String attributionJson})? getAttributionJson(
    String articleId,
  ) => _dao.getRawJson(articleId);

  ReadingMode readingMode(String articleId) =>
      _dao.getReadingMode(articleId) ?? ReadingMode.enOnly;

  void setReadingMode(String articleId, ReadingMode mode) =>
      _dao.setReadingMode(articleId, mode);

  /// Directory the importer stages files into; final immutable location.
  Directory artifactDirectory(ArticleRef ref) =>
      _dirs.articleDir(ref.articleId, ref.revision, ref.artifactRevision);

  /// Commits a validated, fully-moved import: the single DB transaction
  /// that switches the article's current pointer (design §8.2). The packaged
  /// translation rows are written by the translation-owner seam inside the
  /// same transaction; a package carrying one without a wired seam fails
  /// fast instead of silently dropping the translation.
  void commitInstall(ValidatedArticleImport install) {
    if (install.translation != null && _installPackagedTranslation == null) {
      throw AppFailure(
        FailureKind.database,
        'packaged translation installer is not wired',
      );
    }
    try {
      _dao.installArticle(
        install,
        installPackagedTranslation: _installPackagedTranslation,
      );
      _notify();
    } catch (e) {
      throw AppFailure(
        FailureKind.database,
        'install commit failed',
        detail: e.toString(),
      );
    }
  }

  /// Duplicate matches for the confirmation page (§6.3): exact raw bytes
  /// first, then content duplicates (same normalized hash + syntax).
  ({List<InstalledArticle> exact, List<InstalledArticle> content}) duplicates({
    required String sourceSha256,
    required String normalizedSha256,
    required String sourceSyntax,
  }) {
    final exact = _dao.findBySourceSha256(sourceSha256);
    final content = _dao
        .findByContentIdentity(
          normalizedSha256: normalizedSha256,
          sourceSyntax: sourceSyntax,
        )
        .where((a) => a.sourceSha256 != sourceSha256)
        .toList();
    return (exact: exact, content: content);
  }

  /// Deletes the article's DB rows and all on-disk artifacts.
  /// Vocabulary snapshots are untouched (design §3.1, screen 05).
  ///
  /// Refuses while a playback session holds the article's audio (design §6.3):
  /// the caller stops the active session first, then deletes. The lease guard
  /// is the last line of defense against a race between stop and delete.
  Future<void> deleteArticle(String articleId) async {
    if (_leases?.isLeasedArticle(articleId) ?? false) {
      throw const AppFailure(
        FailureKind.player,
        'article is currently playing; stop it first',
      );
    }
    try {
      _dao.deleteArticle(articleId);
      _notify();
    } catch (e) {
      throw AppFailure(
        FailureKind.database,
        'delete failed',
        detail: e.toString(),
      );
    }
    final root = _dirs.articleRootDir(articleId);
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  /// Removes artifact directories no longer referenced after an upgrade
  /// (MOB-IMP-003). Never touches the current artifact, vocabulary, or an
  /// artifact a background session still holds (design §6.3): a leased dir is
  /// skipped and retried via [retryCleanup] once the lease drops.
  Future<void> cleanupOldArtifacts(ArticleRef current) async {
    final root = _dirs.articleRootDir(current.articleId);
    if (!await root.exists()) return;
    final currentPath = artifactDirectory(current).path;
    await for (final revisionDir in root.list()) {
      if (revisionDir is! Directory) continue;
      await for (final artifactDir in revisionDir.list()) {
        if (artifactDir is! Directory) continue;
        if (artifactDir.path == currentPath) continue;
        if (_leases?.isLeasedWithin(artifactDir.path) ?? false) continue;
        await artifactDir.delete(recursive: true);
      }
      // Remove emptied revision directories.
      if (await revisionDir.list().isEmpty) {
        await revisionDir.delete();
      }
    }
  }

  /// Re-runs [cleanupOldArtifacts] for [ref]'s article after a playback lease
  /// releases. Best-effort: failures are swallowed (the next import/lease
  /// release retries).
  ///
  /// [ref] comes from the released lease and may be stale — an upgrade may
  /// have committed a newer version while the session was playing. Passing it
  /// straight to [cleanupOldArtifacts] would protect the *old* directory and
  /// delete the live one, so the current version is re-read from the DAO (same
  /// pattern as the importer's startup recovery).
  Future<void> retryCleanup(ArticleRef ref) async {
    try {
      final current = _dao.getArticle(ref.articleId);
      if (current == null) return; // deleted while leased
      await cleanupOldArtifacts(current.ref);
    } catch (_) {
      // Swallowed: cleanup is idempotent and retried on the next opportunity.
    }
  }
}
