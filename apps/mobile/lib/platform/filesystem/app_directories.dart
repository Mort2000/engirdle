import 'dart:io';

import 'package:path/path.dart' as p;

/// Controlled app-private data layout (design §8.1):
///
/// ```
/// app-private-data/
/// ├── app.db
/// ├── dictionaries/{dictionary_id}/{revision}/dictionary.db
/// ├── articles/{article_id}/{revision}/{artifact_revision}/
/// ├── staging/{import_id}/
/// └── downloads/{import_id}.readpack   (temporary download area)
/// ```
///
/// All paths are built from validated IDs only; external input never becomes
/// a filesystem path directly.
class AppDirectories {
  AppDirectories(this.root);

  final Directory root;

  File get databaseFile => File(p.join(root.path, 'app.db'));

  Directory articleDir(String articleId, int revision, int artifactRevision) =>
      Directory(p.join(
        root.path,
        'articles',
        _safeId(articleId),
        revision.toString(),
        artifactRevision.toString(),
      ));

  /// All installed artifact directories of one article revision.
  Directory articleRevisionDir(String articleId, int revision) => Directory(
      p.join(root.path, 'articles', _safeId(articleId), revision.toString()));

  Directory articleRootDir(String articleId) =>
      Directory(p.join(root.path, 'articles', _safeId(articleId)));

  Directory stagingDir(String importId) =>
      Directory(p.join(root.path, 'staging', _safeId(importId)));

  Directory downloadsDir() => Directory(p.join(root.path, 'downloads'));

  File downloadFile(String importId) =>
      File(p.join(downloadsDir().path, '${_safeId(importId)}.readpack'));

  Directory dictionaryDir(String dictionaryId, int revision) => Directory(p.join(
      root.path, 'dictionaries', _safeId(dictionaryId), revision.toString()));

  Future<void> ensureBaseLayout() async {
    await downloadsDir().create(recursive: true);
    await Directory(p.join(root.path, 'staging')).create(recursive: true);
    await Directory(p.join(root.path, 'articles')).create(recursive: true);
    await Directory(p.join(root.path, 'dictionaries')).create(recursive: true);
  }

  /// IDs that may become path segments: opaque contract IDs and UUIDs only.
  static final _idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$');

  static String _safeId(String id) {
    if (id.isEmpty || id.length > 128 || !_idPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'unsafe path id');
    }
    if (id.contains('..')) {
      throw ArgumentError.value(id, 'id', 'path traversal');
    }
    return id;
  }
}
