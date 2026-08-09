import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../contracts/readpack_v1/article.dart';
import '../../../contracts/readpack_v1/manifest.dart';
import '../../../platform/filesystem/app_directories.dart';
import '../../../shared_kernel/content_identity.dart';
import '../../../shared_kernel/failures.dart';
import '../../playback/domain/lease_registry.dart';
import '../domain/installed_article.dart';
import '../infrastructure/library_dao.dart';

/// Library use cases: installed-article index, content queries, atomic
/// install commit and safe deletion (MOB-LIB-001, MOB-IMP-002/003).
class LibraryService {
  LibraryService({
    required LibraryDao dao,
    required AppDirectories directories,
    LeaseRegistry? playbackLeases,
  })  : _dao = dao,
        _dirs = directories,
        _leases = playbackLeases;

  final LibraryDao _dao;
  final AppDirectories _dirs;

  /// Last-resort guard so an upgrade cleanup or a delete cannot remove an
  /// artifact a background playback session still holds (design §6.3). Null in
  /// tests that don't care about playback.
  final LeaseRegistry? _leases;

  List<InstalledArticle> listArticles() => _dao.listArticles();

  InstalledArticle? getArticle(String articleId) => _dao.getArticle(articleId);

  /// Full content for the reader; null when the article is not installed.
  InstalledContent? getContent(String articleId) {
    final article = _dao.getArticle(articleId);
    if (article == null) return null;
    final audioFile = File(p.join(
      _dirs
          .articleDir(articleId, article.revision, article.artifactRevision)
          .path,
      'audio',
      'article.m4a',
    ));
    return InstalledContent(
      article: article,
      blocks: _dao.getBlocks(articleId),
      audioFilePath: audioFile.path,
    );
  }

  /// Raw manifest/attribution JSON for the attribution page.
  ({String manifestJson, String attributionJson})? getAttributionJson(
          String articleId) =>
      _dao.getRawJson(articleId);

  ReadingMode readingMode(String articleId) =>
      _dao.getReadingMode(articleId) ?? ReadingMode.enOnly;

  void setReadingMode(String articleId, ReadingMode mode) =>
      _dao.setReadingMode(articleId, mode);

  /// Directory the importer stages files into; final immutable location.
  Directory artifactDirectory(ArticleRef ref) =>
      _dirs.articleDir(ref.articleId, ref.revision, ref.artifactRevision);

  /// Commits a validated, fully-moved package: the single DB transaction
  /// that switches the article's current pointer (design §8.2).
  void commitInstall({
    required ArticleContent content,
    required ReadpackManifest manifest,
    required String manifestJson,
    required String attributionJson,
  }) {
    try {
      _dao.installArticle(
        content: content,
        manifest: manifest,
        manifestJson: manifestJson,
        attributionJson: attributionJson,
      );
    } catch (e) {
      throw AppFailure(FailureKind.database, 'install commit failed',
          detail: e.toString());
    }
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
          FailureKind.player, 'article is currently playing; stop it first');
    }
    try {
      _dao.deleteArticle(articleId);
    } catch (e) {
      throw AppFailure(FailureKind.database, 'delete failed',
          detail: e.toString());
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
