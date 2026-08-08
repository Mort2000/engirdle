import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../contracts/readpack_v1/article.dart';
import '../../../contracts/readpack_v1/manifest.dart';
import '../../../platform/filesystem/app_directories.dart';
import '../../../shared_kernel/content_identity.dart';
import '../../../shared_kernel/failures.dart';
import '../domain/installed_article.dart';
import '../infrastructure/library_dao.dart';

/// Library use cases: installed-article index, content queries, atomic
/// install commit and safe deletion (MOB-LIB-001, MOB-IMP-002/003).
class LibraryService {
  LibraryService({
    required LibraryDao dao,
    required AppDirectories directories,
  })  : _dao = dao,
        _dirs = directories;

  final LibraryDao _dao;
  final AppDirectories _dirs;

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
  Future<void> deleteArticle(String articleId) async {
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
  /// (MOB-IMP-003). Never touches the current artifact or vocabulary.
  Future<void> cleanupOldArtifacts(ArticleRef current) async {
    final root = _dirs.articleRootDir(current.articleId);
    if (!await root.exists()) return;
    final currentPath =
        artifactDirectory(current).path;
    await for (final revisionDir in root.list()) {
      if (revisionDir is! Directory) continue;
      await for (final artifactDir in revisionDir.list()) {
        if (artifactDir is Directory && artifactDir.path != currentPath) {
          await artifactDir.delete(recursive: true);
        }
      }
      // Remove emptied revision directories.
      if (await revisionDir.list().isEmpty) {
        await revisionDir.delete();
      }
    }
  }
}
